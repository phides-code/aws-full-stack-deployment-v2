# AWS Full-Stack Deployment Template

This project provides a fully-automated template for deploying multiple serverless services—each with its own database table—under a single CloudFront distribution. It uses simple Bash scripts to scaffold GitHub repos, generate CloudFormation stacks, configure secure CloudFront headers, and deploy both backend and frontend stacks.

## What Does This Deploy?

- **Backend:**
    - Go Lambda service (CRUD for your chosen entity)
    - API Gateway endpoint
    - DynamoDB table (name is based on your provided singular entity name)
    - Secured by CloudFront-injected custom header, verified in Lambda
    - Automatically deployed through GitHub Actions
    - One CloudFront distribution can host many services

- **Frontend:**
    - React + TypeScript + Redux Toolkit Query
    - Basic CRUD interface for the deployed backend service
    - Hosted in S3 and served through CloudFront
    - Automatically built and deployed via GitHub Actions
    - No SigV4 — requests are protected by CloudFront-only access

## Features

- **CloudFront API secure channel using custom header**
    - Only CloudFront can call the API. Lambda verifies the secret.
- **Multiple services in one CloudFront distribution**
    - Deploy additional backends and frontends into the same project.
- **Automated setup**
    - GitHub repo creation (public or private)
    - Secrets injection (AWS keys + CloudFront secret)
    - Template variable replacement in both backend + frontend
- **Automated CI/CD**
    - Backend: Go build → CloudFormation deploy
    - Frontend: Vite build → S3 sync → CloudFront invalidation

## Prerequisites

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) configured with appropriate credentials
- Bash shell (Linux or macOS recommended)
- jq (for JSON processing, if used in scripts)
- [git](https://git-scm.com/) (for version control and repository setup)
- [GitHub CLI (gh)](https://cli.github.com/) (for repository creation and deployment automation)
- [npx](https://www.npmjs.com/package/npx) (Node 18+ recommended)

## Setup Instructions

1.  Clone this repository:
    ```bash
    git clone phides-code/aws-full-stack-deployment
    cd aws-full-stack-deployment
    ```
2.  Run the setup script:
    - The script expects two arguments:

    ```bash
    /setup.sh <project-name> <table-name-in-singular>
    ```

    - Replace `<project-name>` with a unique name for your deployment. This name will be used to namespace your AWS resources.
    - Replace `<table-name-in-singular>` with a singular entity name (e.g. `banana`)

## Usage

- Each backend provides a REST CRUD API wired to a DynamoDB table.
- The frontend is pre-wired to the initial backend API.
- All configuration values (service name, table name, region, CloudFront secret) are injected automatically.
- You can customize everything in the generated repos.

## Cleanup

To remove all deployed resources, run:

```bash
./delete-all.sh
```

## License

This project is provided as-is for educational and demonstration purposes. Please review and adapt all scripts and policies for your production needs.
