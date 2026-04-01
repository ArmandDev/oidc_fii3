# CloudPulse — deployment guide (DR stack only)

This repo uses **one** active Terraform scenario: **`dr.tf`**. That file bundles what used to live in separate **data-at-rest encryption** and **high-availability** stacks, plus **multi-region DR**. The narrative lives in the banner comment at the top of `dr.tf`.

**Active files:** `provider.tf`, `variables.tf`, `dr.tf`. DR outputs are defined at the bottom of `dr.tf`. **`main.tf`** is the Session 3 lab (with its own outputs at the bottom of that file); do not enable it alongside `dr.tf`.

## Prerequisites

1. **AWS**: CI/CD or local credentials with permissions for VPC, EC2, ALB, ASG, S3, DynamoDB, KMS, CloudFront, WAF, SNS, Lambda, IAM, etc. Session 3 / `main.tf` default region: **`eu-west-2`** (`variables.tf` → `aws_region`). DR workloads use `aws.secondary` (**eu-west-3** in `provider.tf`). Remote state S3 backend region stays as configured in `provider.tf` (may differ from deploy region).

2. **ACM (us-east-1)**: CloudFront needs a certificate in **us-east-1** for your public hostname. `dr.tf` uses `data.aws_acm_certificate.disaster` (default domain `disaster.derherzen.com`). Issue and validate that cert before apply, or uncomment resources in `certificate.tf` if you want Terraform to own the cert.

3. **DNS**: Add validation CNAMEs while the cert is pending; after deploy, CNAME your app hostname to the CloudFront domain from Terraform output `dr_cloudfront_domain_name`.

4. **`variables.tf`**: Set `allowed_ssh_cidrs` to your IP if you use SSH. Tune `dr_standby_desired_capacity`, `dr_route53_automatic_failover`, and `dr_lambda_scale_*` as needed.

## Deploy

1. Ensure only **`dr.tf`** defines infrastructure (not `main.tf`).
2. `terraform init` / push through pipeline → `terraform apply`.
3. Outputs to use: `dr_cloudfront_domain_name`, `dr_manual_failover_aws_cli`, `dr_manual_lambda_invoke_cli`, `dr_automatic_failover_note`, alarm name output if present.

## What to explore

- **Encryption**: S3 / DynamoDB / EBS SSE-KMS; S3 deny unencrypted PUT; MRK + replica key in DR region.
- **HA in primary**: Multi-AZ ASG (e.g. min 2), internal ALB, CloudFront **VPC origins**, WAF, shared verify header.
- **Global data**: S3 CRR and DynamoDB global table replica (see `dr.tf` and AWS console).
- **Failover**: CloudFront **origin group** (HTTP errors) + optional **CloudWatch** primary ASG **`GroupInServiceInstances`** (ALARM when **0**) → **SNS** → **Lambda** scales DR ASG (see `dr_route53_automatic_failover`).

Suggested DR test: cold DR (`dr_standby_desired_capacity = 0`), hit the app, break primary targets, trigger alarm or manual SNS/Lambda, confirm DR capacity and origin failover.

## Destroy

- Remove or comment `dr.tf` resources (or `terraform destroy` with this workspace), then clean up DNS if you no longer need the hostname.

## Cleanup notes

- **`certificate.tf`** is optional and mostly commented; if you manage certs outside Terraform, leave it as-is.
- Costs: multi-region and CloudFront/WAF add billing; tear down when finished.
