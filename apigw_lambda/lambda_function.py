import boto3
import os

# Initialize AWS SSM client
ssm = boto3.client('ssm')

def lambda_handler(event, context):
    try:
        # Get the parameter name from environment variable
        param_name = os.environ.get('PARAM_NAME', '/dynamic_string')
        
        # Fetch the dynamic string from AWS SSM Parameter Store
        response = ssm.get_parameter(Name=param_name, WithDecryption=False)
        dynamic_string = response['Parameter']['Value']
        
        # Generate the HTML response
        html_content = f"""
        <html>
            <head>
                <title>Dynamic String Page</title>
            </head>
            <body>
                <h1>The saved string is {dynamic_string}</h1>
            </body>
        </html>
        """

        return {
            "statusCode": 200,
            "headers": {
                "Content-Type": "text/html"
            },
            "body": html_content
        }

    except Exception as e:
        print(f"Error retrieving parameter: {str(e)}")
        return {
            "statusCode": 500,
            "body": "Internal Server Error"
        }

