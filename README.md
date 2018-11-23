# Vibrato Test
This project generates the infrastructure and deploys the Vibrato TechTestApp to AWS using Terraform.

## Pre-requisites 

- AWS Account
- AWS Cli
- [Terraform](https://www.terraform.io/) installed locally

## Pre-Configuration
There are a few things we need in place before we can Terraform our AWS account to generate our infrastructure and deploy our application stack.

### Credentials
We need IAM credentials (access-key-id and access-key) with the following 

### S3
We will store our Terraform state files in S3. In order to do this we'll need an S3 bucket.

### KMS
We'll use KMS to encrypt the state files in S3 in order to prevent any credentials from being stored in SCM. Store the KMS ID in a file named: `kms_key_id`

### Generate a Postgres Password
- Generate a secure password for postgres. I like to use [xkpasswd](https://xkpasswd.net/s/)
- Store it in a file named `secret_postgres_password`.
- We'll next use KMS to encrypt that password for storage at rest in Git:

```
aws kms encrypt --key-id fileb://kms_key_id --plaintext fileb://secret_postgress_password --output text --query CiphertextBlob | base64 --decode > secret_postgress_password.encoded
```

```
aws kms decrypt --ciphertext-blob fileb://secret_postgress_password.encoded --output text --query Plaintext | base64 --decode > secret_postgress_password
```

### Github Token
- Generate a personal access token a guide is available [here](https://docs.aws.amazon.com/codepipeline/latest/userguide/GitHub-rotate-personal-token-CLI.html). 
- Store the token in a file named `secret_github`
- We'll next use KMS to encrypt the token at rest in Git:

```
aws kms encrypt --key-id fileb://kms_key_id --plaintext fileb://secret_github --output text --query CiphertextBlob | base64 --decode > secret_github.encoded
```

```
aws kms decrypt --ciphertext-blob fileb://secret_github.encoded --output text --query Plaintext | base64 --decode > secret_github
```


### Tagging
We'll add the following tag to all of the resources we create so we can easily track their cost:

```
Key: project Value: vibrato-techtest
```

## Collaboration
If you plan to iterate on this project you will need to solve the problem of concurrency. Probably easiest to [enable locking](https://www.terraform.io/docs/backends/types/s3.html) on the Terraform S3 backend.