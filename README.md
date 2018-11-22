# Vibrato Test
This project generates the infrastructure and deploys the Vibrato TechTestApp to AWS using Terraform.

## Pre-requisites 

- AWS Account
- [Terraform](https://www.terraform.io/) installed locally

## Pre-Configuration
There are a few things we need in place before we can Terraform our AWS account to generate our infrastructure and deploy our application stack.

### Credentials
We need IAM credentials (access-key-id and access-key) with the following 

### S3
We will store our Terraform state files in S3. In order to do this we'll need an S3 bucket.

### KMS
We'll use KMS to encrypt the state files in S3 in order to prevent any credentials from being stored in SCM.

```
aws kms encrypt --key-id fileb://kms_key_arn --plaintext fileb://secret_password --output text --query CiphertextBlob | base64 --decode > secret_password.encoded
```

```
aws kms decrypt --ciphertext-blob fileb://secret_password.encoded --output text --query Plaintext | base64 --decode > secret_password
```

### Tagging
We'll add the following tag to all of the resources we create so we can easily track their cost:

```
Key: project Value: vibrato-techtest
```

## Collaboration
If you plan to iterate on this project you will need to solve the problem of concurrency. Probably easiest to [enable locking](https://www.terraform.io/docs/backends/types/s3.html) on the Terraform S3 backend.