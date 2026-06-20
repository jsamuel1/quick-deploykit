#!/usr/bin/env node
import { App } from 'aws-cdk-lib/core';
import { AmazonQuickSuiteStack } from './amazon-quick-suite-starter-kit-stack';
import { CognitoProxyStack } from './quick-desktop/stacks/cognito-proxy-stack';
import {
  ProjectName,
  QuickDesktopConfig,
  createStackName,
} from './quick-desktop/common/config';

/* Region is pinned so the deploy target does not depend on the shell's
 * AWS_REGION/CDK_DEFAULT_REGION (which may differ). Account is still taken
 * from the current CLI profile (sauhsoj+ct-primary-Admin -> 747436374768). */
const REGION = 'ap-southeast-2';
const env = {
  account: process.env.CDK_DEFAULT_ACCOUNT,
  region: REGION,
};

const app = new App();

// Stack 1: Amazon Quick Suite subscription + IAM Identity Center wiring.
new AmazonQuickSuiteStack(app, 'AmazonQuickSuiteStack', { env });

// Stack 2: Cognito OIDC provider + proxy for Amazon Quick on desktop.
// MFA is required for all users; the API Gateway is left open (no CIDR
// allowlist). Override allowedCidrs/retain via -c context if needed.
const allowedCidrs = app.node.tryGetContext('allowedCidrs') as
  | string[]
  | undefined;
const retainResources = app.node.tryGetContext('retain') === 'true';

const desktopConfig: QuickDesktopConfig = {
  projectName: ProjectName.QUICK_DESKTOP,
  retainResources,
  mfaRequired: true,
  ...(allowedCidrs && { allowedCidrs }),
};

new CognitoProxyStack(
  app,
  createStackName(desktopConfig.projectName, 'CognitoProxy'),
  { config: desktopConfig, env },
);
