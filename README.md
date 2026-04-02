# OIDC FII Project

## Overview

This project demonstrates the integration of OpenID Connect (OIDC) between AWS and GitHub for secure, automated infrastructure deployment using Terraform. The project deploys a simple web application, along with a monitoring stack consisting of Prometheus, Grafana, Loki, and Promtail for observability, and Locust for load testing.

The infrastructure is defined using Terraform, and the deployment is automated via a GitHub Actions workflow that leverages OIDC for authentication with AWS, eliminating the need for long-lived credentials.

## Architecture

- **Application**: A Python Flask app deployed on AWS (likely ECS or similar).
- **Monitoring Stack**:
  - **Prometheus**: Collects metrics from the application (e.g., request counts, response times) and node exporters (system metrics like CPU, memory). It scrapes data from configured targets at regular intervals.
  - **Grafana**: Visualizes metrics from Prometheus in dashboards. It provides customizable charts and alerts based on the collected data.
  - **Loki**: Aggregates and stores logs from the application and infrastructure. It indexes logs for efficient querying.
  - **Promtail**: Ships logs from containers and files to Loki. It tails log files and sends them to the Loki server.
- **Load Testing**: Locust for performance testing.
- **Infrastructure as Code**: Terraform manages AWS resources.

## Prerequisites

Before running this project, ensure you have:

- An AWS account with appropriate permissions.

## Setup Instructions

Follow these steps to set up and run the project:

### 1. Fork the Repository

1. Go to the [original repository](https://github.com/IustinAchitenei/oidc_fii).
2. Click the "Fork" button in the top-right corner.
3. Start a codespace in your forked repository.

### 2. Set Up OIDC Connection Between AWS and GitHub

To enable secure authentication from GitHub Actions to AWS:

1. In your AWS account, create an IAM OIDC provider for GitHub:
   - Go to IAM > Identity Providers.
   - Create a new provider with the following details:
     - Provider type: OpenID Connect.
     - Provider URL: `https://token.actions.githubusercontent.com`.
     - Audience: `sts.amazonaws.com`.

2. Create an IAM role that trusts the OIDC provider:
   - Create a new IAM role with the following trust policy:

     ```json
     {
       "Version": "2012-10-17",
       "Statement": [
         {
           "Effect": "Allow",
           "Principal": {
             "Federated": "arn:aws:iam::YOUR_AWS_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
           },
           "Action": "sts:AssumeRoleWithWebIdentity",
           "Condition": {
             "StringEquals": {
               "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
             },
             "StringLike": {
               "token.actions.githubusercontent.com:sub": [
                   "repo:YOUR_USERNAME/oidc_fii:refs/heads/main",
                   "repo:YOUR_USERNAME/oidc_fii:refs/heads/main"
               ]
             }
           }
         }
       ]
     }
     ```

   - Attach policies to the role that grant necessary permissions: AdministratorAccess.

3. Note the ARN of this IAM role; you'll need it for the next step.

### 3. Add Variables to Repository Secrets

In your forked GitHub repository:

1. Go to Settings > Secrets and variables > Actions.
2. Add the following secrets:
   - `ROLE_TO_ASSUME`: The ARN of the IAM role created in step 2.
   - `AWS_REGION`: Region for the GitHub Actions AWS session (API calls are not limited to this region). Default workload regions: **`eu-west-1`** Session 3 (`var.main_aws_region`), **`eu-west-2`** DR primary (`var.aws_region`), **`eu-west-3`** DR secondary (`var.dr_secondary_region`).

### 4. Create S3 Bucket for Terraform State

1. In the AWS Management Console, create a new S3 bucket:
   - Bucket name: Choose a unique name (e.g., `your-username-oidc-fii-state`).
   - Region: same as the `region` in `provider.tf` `backend "s3"` (currently **`eu-north-1`** in this repo—can differ from workload regions **`eu-west-1` / `eu-west-2` / `eu-west-3`**).

2. In the `provider.tf` file, replace `YOUR_BUCKET_NAME` with your actual S3 bucket name.

### 5. Modify the GitHub Actions Workflow

1. Open `.github/workflows/terraform.yml`.
2. Uncomment all steps except the "Terraform Destroy" step (which should remain commented out for now).

### 6. Commit and Push Changes

1. Add all changes:

   ```bash
   git add -A
   ```

2. Commit the changes:

   ```bash
   git commit -m "Setup OIDC and configure Terraform"
   ```

3. Push to your forked repository:

   ```bash
   git push origin main
   ```

## Running the Project

After pushing the changes, the GitHub Actions workflow will automatically trigger:

1. The pipeline will authenticate with AWS using OIDC.
2. Terraform will initialize, plan, and apply the infrastructure.
3. The application, monitoring stack, and load testing setup will be deployed.

Monitor the Actions tab in your GitHub repository for the workflow progress.

## Accessing the Services

Once the pipeline completes successfully, the following URLs will be output at the end of the pipeline logs:

- **Application URL**: The URL to access the deployed Flask app.
- **Grafana URL**: Access the Grafana dashboard for monitoring.
- **Locust URL**: Access the Locust web interface for load testing.

### Importing Grafana Dashboards

The app dashboard is automatically imported. In Grafana, additionally import the following dashboards manually:

1. **Node Exporter Dashboard (ID: 1860)**: Monitors the app instance's system metrics (CPU, memory, disk, etc.). Import from the JSON file at `monitoring/grafana/provisioning/dashboards/node.json`.
2. **cAdvisor Dashboard (ID: 19908)**: Monitors container metrics. Import from the JSON file at `monitoring/grafana/provisioning/dashboards/app.json`.

### Setting Up Alerts

In Grafana, you can set up alerts for key metrics:

- **Node Dashboard (%CPU Alert)**: Create an alert rule for CPU usage exceeding 80%. Go to the Node Exporter dashboard, select a CPU panel, and configure an alert condition based on the CPU usage metric.
- **Application Dashboard (Requests per Minute Alert)**: Create an alert rule for requests per minute exceeding a threshold (e.g., 100). Select the requests panel and set up an alert based on the request rate metric.

Alerts can be configured to send notifications via email, Slack, or other channels.

## Cleanup

To destroy the infrastructure:

1. Uncomment the "Terraform Destroy" step in `.github/workflows/terraform.yml`.
2. Commit and push the change to trigger the destroy workflow.


## Troubleshooting

- Ensure your AWS account has the necessary permissions for the resources being created.
- Check the GitHub Actions logs for any errors during deployment.
- Verify that the OIDC setup is correct by checking the IAM role trust relationships.

## Contributing

Feel free to fork, modify, and submit pull requests. For issues, please open a GitHub issue in the repository.

## License

This project is licensed under the MIT License.