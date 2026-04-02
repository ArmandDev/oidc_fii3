# CloudPulse — deployment guide



**Active Terraform:** `main.tf` (Session 3 lab) and `dr.tf` (encryption + HA + multi-region DR) together. They use **separate provider aliases** and **distinct name prefixes** so one `terraform apply` can deploy both.



**Regions (defaults):**



- **Session 3** → `var.main_aws_region` (**`eu-west-1`**), provider **`aws.main`**.

- **DR primary** (VPC, ALB, ASG, SNS, …) → `var.aws_region` (**`eu-west-2`**), default **`aws`**.

- **DR secondary** (replica VPC, replica bucket, Lambda, …) → `var.dr_secondary_region` (**`eu-west-3`**), provider **`aws.secondary`**.



Outputs: Session 3 at the bottom of `main.tf`; DR at the bottom of `dr.tf`.



## Prerequisites



1. **AWS**: Permissions for VPC, EC2, ALB, ASG, S3, DynamoDB, KMS, CloudFront, WAF, SNS, Lambda, IAM, etc., in **all three** workload regions above (or adjust variables). Remote state S3 backend region in `provider.tf` may differ.



2. **ACM (us-east-1)**: CloudFront needs a certificate in **us-east-1** for your public hostname. `dr.tf` uses `data.aws_acm_certificate.disaster` (default `disaster.derherzen.com`). Issue and validate that cert before apply, or use `certificate.tf` if you want Terraform to own the cert.



3. **DNS**: Validation CNAMEs for ACM; after deploy, CNAME your hostname to the CloudFront domain from `dr_cloudfront_domain_name`.



4. **`variables.tf`**: Set `allowed_ssh_cidrs` as needed. Tune `dr_standby_desired_capacity`, `dr_route53_automatic_failover`, and `dr_lambda_scale_*` for DR.



## Deploy



1. `terraform init` → `terraform apply` (pipeline or local).

2. Session 3 URLs: `app_url`, `monitoring_url`, `locust_url` from `main.tf`.

3. DR: `dr_cloudfront_domain_name`, `dr_manual_failover_aws_cli`, `dr_manual_lambda_invoke_cli`, `dr_automatic_failover_note`, etc.



## What to explore



See the banner in `dr.tf` for the full DR narrative (encryption, HA, CRR, global DynamoDB, failover). Session 3 adds the simple two-instance observability lab in **`eu-west-1`**.



## Destroy



`terraform destroy` removes resources tracked in state (expect a long run). **KMS:** the multi-Region key and its replica use `lifecycle { prevent_destroy = true }`, so Terraform will not delete them until you remove that block (or remove those resources from state). That preserves one long-lived CMK while still using the same state bucket and OIDC role. Clean up DNS if you no longer need the hostname.



## Cleanup notes



- **`certificate.tf`** is optional and mostly commented if you manage certs outside Terraform.

- Costs: three regions + CloudFront/WAF add billing; tear down when finished.

