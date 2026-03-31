"""Scale the DR Auto Scaling group when invoked (SNS from CloudWatch or manual test invoke)."""
import json
import os

import boto3


def lambda_handler(event, context):
    asg = os.environ["ASG_NAME"]
    desired = int(os.environ.get("DESIRED_CAPACITY", "2"))
    min_size = int(os.environ.get("MIN_SIZE", "1"))
    region = os.environ["AWS_REGION"]
    client = boto3.client("autoscaling", region_name=region)
    client.update_auto_scaling_group(
        AutoScalingGroupName=asg,
        MinSize=min_size,
        DesiredCapacity=desired,
    )
    return {
        "statusCode": 200,
        "body": json.dumps({"asg": asg, "min_size": min_size, "desired": desired}),
    }
