# Network access — reaching the private gateway

The gateway's ALB is **internal and IPv4-only**. This is not a preference — it's
a hard requirement:

> Claude Code's `/login` **rejects any gateway whose hostname resolves to a
> public IP.** A trusted gateway can push managed-settings that run commands on
> developer machines, so the client refuses to trust one reachable at a public
> IP. Dual-stack internal ALBs also hand out public-range IPv6 (AAAA) records,
> which `/login` rejects too — hence IPv4-only.

So the only thing this module has to guarantee is:

1. **Private reachability** — developer machines can open TCP 443 to the internal
   ALB's private IPs inside the gateway VPC.
2. **Private DNS resolution** — the gateway hostname (e.g.
   `claude-gateway.internal.example.com`) resolves to those private IPs on the
   developer's machine.

**A VPN is one way to deliver that — not a requirement.** If your organization
already has connectivity into AWS, use it. You do **not** need to stand up a new
VPN endpoint.

---

## Option A (recommended if you have it): bring your own connectivity

If developers already reach your AWS network through any of these, you're almost
done — there is **no CloudFormation to deploy here**:

| You already have | What to do |
|------------------|------------|
| Corporate **Client VPN** / SSL VPN | Route the gateway VPC CIDR over the tunnel; set the gateway's `ClientCidr` to your VPN client pool. |
| **AWS Direct Connect** | Ensure the gateway VPC is reachable over the DX VIF; set `ClientCidr` to your on-prem/client CIDR. |
| **Site-to-Site VPN** | Same as Direct Connect — route the VPC CIDR, set `ClientCidr`. |
| **Transit Gateway** | Attach the gateway VPC to the TGW; propagate routes; set `ClientCidr` to the source CIDR. |
| **VPC peering** (e.g. from a VDI/WorkSpaces VPC) | Peer to the gateway VPC; add routes both ways; set `ClientCidr` to the peer CIDR. |

Two knobs make it work:

1. **`ClientCidr` on the gateway stack** — the ALB security group allows 443 from
   this CIDR. Set it to the client/source range that arrives over your existing
   connection. (Traffic originating inside the gateway VPC is always allowed.)

2. **Private DNS** — the gateway creates a Route 53 **private hosted zone**
   associated with its own VPC. Your clients must resolve names in that zone:
   - **TGW / peering (in-AWS clients):** associate the private hosted zone with
     the client's VPC (`aws route53 associate-vpc-with-hosted-zone`), or use a
     Route 53 **inbound resolver** endpoint.
   - **On-prem over DX / Site-to-Site:** point a conditional forwarder for the
     zone at a Route 53 **inbound resolver** endpoint in the gateway VPC.
   - Alternatively, use your own DNS: create an A/CNAME record for the gateway
     hostname pointing at the ALB's private IPs in a zone your clients already
     resolve. (You still terminate TLS with a cert whose SAN matches the
     hostname — see the deploy guide.)

That's it. Skip Option B entirely.

---

## Option B (fallback): the reference AWS Client VPN

Use this **only if you have no existing private path** into the gateway VPC. It's
a self-contained, mutual-TLS AWS Client VPN endpoint you can stand up in minutes.

Files:

| File | Purpose |
|------|---------|
| `client-vpn.yaml` | Client VPN endpoint associated with the gateway's private subnets; pushes the VPC `.2` resolver so the private zone resolves. |
| `make-vpn-certs.sh` | Generates the mutual-TLS PKI (CA + server + per-developer client certs) with openssl and imports server + CA to ACM. |

Deploy:

```bash
cd infrastructure/network-access

# 1. Generate certs and import to ACM (prints the two ACM ARNs).
export AWS_REGION=<your-region>          # AWS_PROFILE optional
./make-vpn-certs.sh developer1

# 2. Deploy the endpoint, wiring in the gateway stack's VPC/subnet outputs.
aws cloudformation deploy --stack-name claude-gateway-vpn \
  --template-file client-vpn.yaml \
  --region "$AWS_REGION" \
  --parameter-overrides \
    ServerCertificateArn=<from step 1> \
    ClientRootCertificateArn=<from step 1> \
    VpcId=<gateway stack VpcId output> \
    SubnetId1=<gateway PrivateSubnets output, 1st> \
    SubnetId2=<gateway PrivateSubnets output, 2nd> \
    VpcCidr=<gateway VpcCidr output> \
    VpcDnsResolver=<VPC network base + 2, e.g. 10.20.0.2>

# 3. Export a client profile and hand it to a developer.
aws ec2 export-client-vpn-client-configuration \
  --client-vpn-endpoint-id <ClientVpnEndpointId output> \
  --region "$AWS_REGION" --output text > claude-gw.ovpn
# then append the <cert>…</cert> and <key>…</key> from vpn-pki/developer1.{crt,key}
```

The VPN's `ClientCidrBlock` must sit within the gateway stack's `ClientCidr` (the
ALB ingress range). Defaults line up: VPN clients `10.30.0.0/22` ⊂ gateway
`ClientCidr` `10.30.0.0/16`.

> **Generated PKI is secret.** `vpn-pki/`, `*.ovpn`, `*.key`, `*.crt` are
> gitignored — never commit them.

## Troubleshooting

### `claude /login` or `curl https://<gateway>/healthz` hangs after VPN connect

The AWS Client VPN tunnel default MTU (1500) is too high once OpenVPN
encapsulation is added: TCP SYN/ACK still fits, but the TLS `ClientHello` /
`ServerHello` exceed the effective MTU and get silently dropped. DNS resolves,
TCP :443 connects — then everything HTTPS times out.

**Symptoms:**
- `nslookup <gateway>` → private IP ✓
- `nc -z <gateway> 443` → "succeeded" ✓
- `curl -v https://<gateway>/healthz` → hangs at `TLS handshake, Client hello`
- `ping <gateway>` → 100% packet loss (large ICMP dropped for the same reason)

**Fix:** lower the tunnel interface MTU. Identify the `utun*` device holding
your VPN client IP (in the ClientCidrBlock range, e.g. `10.30.0.x`) and reduce
its MTU:

```bash
# 1. Find your VPN tunnel interface
ifconfig | grep -B4 "10.30\."           # shows utunN name

# 2. Lower its MTU (macOS)
sudo ifconfig utun4 mtu 1300            # use whichever utunN you found

# 3. Verify
curl -s --max-time 8 https://<gateway>/healthz    # should return 'ok'
```

**Caveat:** the AWS VPN Client resets MTU to 1500 on every reconnect. Re-run
`sudo ifconfig utunN mtu 1300` after each connect. For a permanent fix, use a
LaunchAgent that watches `ifconfig` for `utun*` on VPN CIDR and re-applies the
MTU, or switch to the `openvpn` CLI where you can bake `tun-mtu 1300` into the
`.ovpn` directly.

### `/login`: "TLS handshake / could not verify" or Firefox HSTS block
Only happens with **self-signed** certs (BYO path). Use the **managed public
ACM cert** path (top-level `README.md` "Design principles") — the cert is
browser-trusted and this whole class of problem disappears. If you must stay on
self-signed: use Chrome or Safari (they read the macOS keychain), and trust the
generated `gateway-ca.pem` via `sudo security add-trusted-cert -d -r trustRoot
-k /Library/Keychains/System.keychain gateway-ca.pem` (Firefox uses its own
store and its HSTS block makes self-signed particularly painful).
