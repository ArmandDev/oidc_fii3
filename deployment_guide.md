# CloudPulse Infrastructure Deployment Guide

This guide provides a step-by-step process for deploying, exploring, and destroying each version of the CloudPulse infrastructure in sequence via CI/CD pipeline. Start with the simple version and progress through increasingly secure and resilient configurations by uncommenting the appropriate files, committing, and pushing changes.

## Prerequisites (Do This Once at the Beginning)

1. **AWS Setup**:
   - Ensure the CI/CD pipeline has AWS credentials configured with sufficient permissions (e.g., AdministratorAccess or equivalent for the services used).
   - Set your default region to `eu-north-1` (or update `variables.tf` if needed).

2. **DNS Preparation**:
   - You must own the domain `derherzen.com` and have access to its DNS settings (e.g., via Route 53 or another provider).
   - For versions with ACM/CloudFront (data_in_transit.tf, high_availability.tf, dr.tf), you'll need to add CNAME records for certificate validation. The Terraform outputs from `certificate.tf` will provide the exact records.
   - For the final access (via CloudFront), add a CNAME record pointing the subdomain to the CloudFront domain (also in outputs).

3. **Repository Setup**:
   - Clone or ensure you have the repo with all files.
   - The `certificate.tf` and `main.tf` are ready (not commented). The others are fully commented—uncomment them to enable deployment.
   - Update `variables.tf` if needed (e.g., change `allowed_ssh_cidrs` to your IP for security).
   - The pipeline will handle Terraform operations automatically on push.

4. **Exploration Tips**:
   - Use AWS Console to inspect resources (EC2, S3, DynamoDB, ALB, CloudFront, etc.).
   - Test the app: Find the ALB/CloudFront URL in outputs or console, access it, and check the Flask app.
   - For encrypted versions, verify S3 objects are encrypted, DynamoDB has SSE, EBS volumes use KMS.
   - Check CloudWatch alarms in the AWS Console for configured metrics (CPU, healthy hosts, etc.).
   - Access AWS Managed Grafana (URL in certificate.tf outputs) to view dashboards with CloudWatch data sources.

## Step 0: Deploy `certificate.tf` (ACM Certificates and Grafana)

**Goal**: Issue ACM certificates for all CloudFront distributions in advance, and set up AWS Managed Grafana.

**Note**: This step is required before deploying any version that uses CloudFront (data_in_transit.tf, high_availability.tf, dr.tf). Certificates must be issued before CloudFront can reference them.

1. **Enable and Deploy via Pipeline**:
   - `certificate.tf` is already uncommented.
   - Commit and push the changes (if any modifications to `variables.tf`).
   - The pipeline will deploy the certificates and Grafana workspace.

2. **Validate Certificates**:
   - Check pipeline outputs or run `terraform output` locally for `transit_validation_records` to get CNAME records.
   - Add the CNAME records to your DNS (e.g., in Route 53) for each domain.
   - Wait 5-10 minutes for AWS to validate and issue the certificates.
   - Verify in AWS Console > Certificate Manager that the certificates show "Issued" status.

3. **Access Grafana**:
   - Get the Grafana URL from `terraform output grafana_workspace_url`.
   - Use AWS SSO to access the managed Grafana workspace.
   - CloudWatch is configured as a data source for creating dashboards.

4. **Keep Deployed**: Do not destroy this until the end of all testing.

## Step 2: Deploy and Explore `main.tf` (Simple Infrastructure)

**Goal**: Basic VPC, EC2, S3, DynamoDB, no encryption or advanced features.

1. **Prepare**:
   - Ensure `main.tf` is uncommented (it should be by default).
   - Update `variables.tf`: Set `allowed_ssh_cidrs` to `["YOUR_PUBLIC_IP/32"]` for SSH access (replace with your IP).

2. **Enable and Deploy via Pipeline**:
   - Uncomment `main.tf` if needed.
   - Commit and push the changes.
   - The pipeline will deploy the infrastructure (~10-15 minutes).

3. **Explore**:
   - **Outputs**: Check pipeline logs or run `terraform output` locally if needed to get instance IPs, ALB DNS, etc.
   - **AWS Console**:
     - EC2: Check the running instance (public IP for SSH: `ssh ec2-user@<public_ip>`).
     - S3: Bucket created, upload/view objects.
     - DynamoDB: Table created, check items.
     - VPC: Subnets, IGW, route tables.
   - **App Test**: SSH to instance, check `/home/ec2-user/app/app.py`. Access ALB DNS (port 80) to see the app.
   - **Monitoring**: Check CloudWatch alarms in AWS Console for any configured metrics.

4. **Destroy**:
   - Comment out `main.tf`.
   - Commit and push.
   - The pipeline will destroy the resources (~5-10 minutes).

## Step 3: Deploy and Explore `data_at_rest.tf` (Data at Rest Encryption)

**Goal**: Adds KMS encryption to S3, DynamoDB, EBS, and S3 bucket policy enforcement.

1. **Prepare**:
   - Uncomment the entire `data_at_rest.tf` file.
   - Update `variables.tf` as in Step 2.

2. **Enable and Deploy via Pipeline**:
   - Commit and push the changes.
   - The pipeline will deploy the infrastructure.

3. **Explore**:
   - **Encryption Check**:
     - S3: Objects encrypted with KMS (check bucket properties > encryption).
     - DynamoDB: Table has SSE-KMS enabled.
     - EBS: Instance volumes use KMS key.
     - Bucket Policy: Try uploading unencrypted object—should fail.
   - **KMS**: Check the created KMS key in AWS Console.
   - Test app and monitoring as in Step 2.

4. **Destroy**:
   - Comment out `data_at_rest.tf`.
   - Commit and push.
   - The pipeline will destroy the resources.

## Step 4: Deploy and Explore `data_in_transit.tf` (Data in Transit Security)

**Goal**: Adds ALB, ASG, CloudFront, WAF, ACM cert for `transit.derherzen.com`.

1. **Prepare**:
   - Uncomment `data_in_transit.tf`.
   - Update `variables.tf` as before.

2. **Enable and Deploy via Pipeline**:
   - Commit and push the changes.
   - The pipeline will deploy the infrastructure (~20-30 minutes due to ASG and CloudFront).

3. **DNS Setup** (Required for HTTPS):
   - Check pipeline outputs or run `terraform output` locally for `acm_validation_records` to get CNAME records.
   - Add them to your DNS for `derherzen.com` (e.g., `_abc123.transit.derherzen.com` → `def456`).
   - Wait 5-10 minutes for validation.
   - Check `cloudfront_domain_name` output (e.g., `d123.cloudfront.net`).
   - Add CNAME: `transit.derherzen.com` → `d123.cloudfront.net`.

4. **Explore**:
   - **ASG**: 2 instances in private subnets, load balanced by ALB.
   - **ALB**: Internal, forwards to ASG on port 8089.
   - **CloudFront**: Serves `https://transit.derherzen.com` with WAF (test SQL injection blocks).
   - **WAF**: Check CloudFront > WAF for rules.
   - **Security**: Instances in private subnets, no direct internet access.
   - Test app via CloudFront URL.

5. **Destroy**:
   - Comment out `data_in_transit.tf`.
   - Commit and push.
   - Remove DNS records after.

## Step 5: Deploy and Explore `high_availability.tf` (High Availability)

**Goal**: Multi-AZ ASG (2 instances), DynamoDB global table, S3 CRR.

1. **Prepare**:
   - Uncomment `high_availability.tf`.
   - Update `variables.tf`.

2. **Enable and Deploy via Pipeline**:
   - Commit and push the changes.
   - The pipeline will deploy the infrastructure (~30-40 minutes).

3. **DNS Setup**:
   - Similar to Step 4, but for `high.derherzen.com`.
   - Add validation CNAMEs and CloudFront CNAME.

4. **Explore**:
   - **ASG**: 2 instances across AZs.
   - **DynamoDB**: Global table with replica in `eu-west-3`.
   - **S3 CRR**: Replication to secondary bucket in `eu-west-3`.
   - Test failover: Simulate AZ outage (stop instances), check auto-scaling.
   - Verify multi-region data sync.

5. **Destroy**:
   - Comment out `high_availability.tf`.
   - Commit and push.
   - Remove DNS records.

## Step 6: Deploy and Explore `dr.tf` (Disaster Recovery)

**Goal**: Same **edge pattern as high availability** (internal ALBs in private subnets, CloudFront **VPC origins**, managed prefix list on ALB security groups, shared `X-CloudPulse-Origin-Verify` header), plus **DR**: second full VPC in `eu-west-3`, **global** data (S3 CRR, DynamoDB replica, MRK), **CloudFront origin failover**, and **automatic or manual** capacity failover to the DR Auto Scaling group.

1. **Prepare**:
   - Comment out every other scenario file that defines the same logical resources (`data_encryption.tf`, `high_availability.tf`, `main.tf`).
   - Leave `provider.tf`, `variables.tf`, and (if you use it) `certificate.tf` as needed. Providers live only in `provider.tf`.
   - Ensure an **issued** ACM cert in **us-east-1** for `disaster.derherzen.com` (see Step 0). The stack uses `data.aws_acm_certificate.disaster`.
   - Optional `variables.tf`: `dr_standby_desired_capacity` (default `0` cold DR), `dr_route53_automatic_failover` (default `true`), `dr_lambda_scale_*` for Lambda targets when alarm/SNS fires.

2. **Deploy**:
   - Commit and push (or run `terraform apply` locally with valid AWS credentials).
   - After apply, read outputs: `dr_cloudfront_domain_name`, `dr_manual_failover_aws_cli`, `dr_manual_lambda_invoke_cli`, `dr_automatic_failover_note`.

3. **DNS**:
   - Point `disaster.derherzen.com` (or your chosen alias from `cloudfront_aliases_dr`) at the CloudFront distribution as in earlier steps.

4. **Explore — two layers of “failover”**:
   - **CloudFront origin group**: On configured error status codes (e.g. 5xx), CloudFront tries the **DR** origin (also a VPC origin with the same verify header). If the DR ASG has **no** instances, the DR origin may still fail until you add capacity (below).
   - **Automatic capacity (optional)**: Because ALBs are **internal**, Route 53 HTTP health checks cannot reach them. Instead, a **CloudWatch alarm** on the primary ALB **`HealthyHostCount`** (namespace `AWS/ApplicationELB`, in your **primary** region) publishes to **SNS** (same region) → **Lambda** in **eu-west-3** scales `${var.project_name}-asg-dr`. Disable the subscription by setting `dr_route53_automatic_failover = false` (the variable name is historical).
   - **Manual capacity (lab exercises)**:
     - **Terraform**: set `dr_standby_desired_capacity` to `1` or `2` and apply (warms DR without SNS).
     - **SNS**: run the `dr_manual_failover_aws_cli` output (same topic the alarm uses).
     - **Lambda**: run the `dr_manual_lambda_invoke_cli` output (AWS CLI v2 may need `--cli-binary-format raw-in-base64-out` with `--payload '{}'`).

5. **Suggested DR test**:
   - With DR cold (`dr_standby_desired_capacity = 0`), open the app **only via CloudFront** (not the internal ALB DNS from a random client).
   - Stop primary ASG instances or scale primary to zero; wait for the **HealthyHostCount** alarm or use manual SNS/Lambda; confirm DR ASG receives capacity and CloudFront origin failover can succeed once DR targets are healthy.

6. **Destroy**:
   - Comment out `dr.tf`.
   - Commit and push.

## Final Notes

- **Time Estimates**: Each deploy/destroy cycle: 30-60 minutes total.
- **Costs**: Monitor AWS billing—encrypted/multi-region resources cost more.
- **Troubleshooting**: If issues, check `terraform validate`, AWS CloudTrail, or logs.
- **Security**: Always restrict `allowed_ssh_cidrs` and use least-privilege IAM.
- **Progression**: Each version builds on the last, adding layers of security and resilience.

## Cleanup All Resources

After testing all versions:

1. **Destroy the last deployed version** (e.g., `dr.tf`):
   - Comment out `dr.tf`.
   - Commit and push.
   - The pipeline will destroy the resources.

2. **Destroy `certificate.tf`**:
   - Comment out `certificate.tf`.
   - Commit and push.
   - The pipeline will destroy the certificates.

3. **Remove DNS records**: Delete the CNAME records added for certificate validation and CloudFront subdomains.

This ensures all resources are cleaned up properly.