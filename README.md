# AppDeployAction

Github Action to update corresponding eks-apps(-sandbox) git repository to trigger application deployment.
After version 3.0, this action handle deployment and override files.

## Inputs
### `app-name`
Application ID to identify the deployment file in eks-apps, Default: extract project name from registry parameter

### `aws-role`
[**Required**] AWS role allowing ECR checks

### `aws-region`
AWS region for ECR checks, Default: eu-central-1

### `debug`
Debug mode (will not update eks-apps repository), Default: false

### `helm-repo`
Repository for eks-apps, Default: `FinalCAD/eks-apps(-sandbox)`

### `helm-ref`
Reference to use for `helm-repo`, Default: master

### `github-token`
Github token to avoid limit rate when pulling package

### `github-ssh`
[**Required**] Github ssh key to pull & change eks-apps repository

### `override-file`
Path for override file, Default: `.finalcad/overrides.yaml`

### `kubernetes-version`
List of kubernetes version to test tthe chart against, default: `1.27.0`

### `registry`
[**Required**] Registry name for app

### `sqitch`
Update only sqitch reference, default app deployment and override is ignored, Default: false, activate this after buidling sqitch image

### `environment`
[**Required**] Finalcad envrionment: production, staging, sandbox

### `regions`
Regions to deploy changes, Default: eu, ap

### `tag`
Iamge reference to deploy and update eks-apps, can be tag or sha, Default: latest image in registry if empty

## Usage

```yaml
- uses: FinalCAD/AppDeployAction@v3.0
  name: Deploy
  with:
    registry: dotnet-backends/api1-service-api
    aws-role: ${{ secrets.DEPLOY_ROLE }}
    environment: sandbox
    github-ssh: ${{ secrets.GH_DEPLOY_SSH }}
    registry: dotnet-backends/api1-service-api
```
