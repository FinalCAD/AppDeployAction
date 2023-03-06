
# AppDeployAction

Github Action to update corresponding eks-apps(-sandbox) git repository to trigger application deployment.

## Inputs
### `app-name`
Application ID to identify the deployment file in eks-apps, Default: extract project name from registry parameter

### `aws-role`
[**Required**] AWS role allowing ECR checks

### `aws-region`
AWS region for ECR checks, Default: eu-central-1

### `debug`
Debug mode (will not update eks-apps repository), Default: false

### `github-ssh`
[**Required**] Github ssh key to pull & change eks-apps repository

### `registry`
[**Required**] Registry name for app

### `sqitch`
Enable sqitch on this deployment, if you enable sqitch, app deployment is disbale, Default: false

### `workdir`
Github action working directory, Default: eks-apps

### `environment`
[**Required**] Finalcad envrionment: production, staging, sandbox

### `regions`
Regions to deploy changes, Default: eu, ap

### `tag`
Iamge reference to deploy and update eks-apps, can be tag or sha, Default: latest image in registry

## Usage

```yaml
- uses: FinalCAD/AppDeployAction@v0.0.1
  name: Deploy
  with:
    app-name: api1-service-api
    aws-role: ${{ secrets.DEPLOY_ROLE }}
    environment: sandbox
    github-ssh: ${{ secrets.GH_DEPLOY_SSH }}
    registry: dotnet-backends/api1-service-api
```
