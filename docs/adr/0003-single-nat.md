# ADR-0003: One NAT gateway in the demo environment

**Status:** Accepted

## Context
Private nodes need outbound internet (public container registries, AWS APIs without endpoints). A NAT gateway costs about $0.045/h plus data processing. The resilient layout is one NAT per AZ, because a NAT gateway is a zonal resource.

## Decision
The demo uses **one NAT gateway**, behind the `single_nat_gateway` flag (default `true`). Setting it to `false` creates one NAT per AZ with per-AZ route tables. A **free S3 gateway endpoint** carries S3 and ECR layer traffic, so most image-pull bytes never touch the NAT.

## Consequences
- Saves 2 × $0.045/h (about $65/month when always on).
- If the NAT's AZ fails, private subnets in the other AZs lose egress. For a demo that is acceptable; for production it is not, and there it is a one-line change reviewed through the PR plan.
- Cross-AZ traffic to the NAT is billed, which is negligible at demo volumes.

## Alternatives considered
- **NAT instances (fck-nat)**: about 10× cheaper, but a self-managed component (patching, HA scripts). It looks like a hack in an architecture review.
- **No NAT, nodes in public subnets**: cheapest, but nodes get public IPs, which is a security anti-pattern.
- **Interface endpoints for every AWS API**: removes the NAT dependency for AWS APIs, but at about $7/month per endpoint per AZ it costs more than the NAT here. Worth it in production for ECR API/STS/SQS.
