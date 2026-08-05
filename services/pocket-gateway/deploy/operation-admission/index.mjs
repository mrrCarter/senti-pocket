import { InvokeCommand } from '@aws-sdk/client-lambda';
import { GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import {
  DeleteCommand,
  GetCommand,
  PutCommand,
} from '@aws-sdk/lib-dynamodb';

import { createOperationAdmissionAwsClients } from './aws-clients.mjs';
import { createOperationAdmissionBootstrap } from './bootstrap.mjs';

const { secretsManagerClient, dynamoDocumentClient, lambdaClient } = createOperationAdmissionAwsClients();

export const handler = createOperationAdmissionBootstrap({
  env: process.env,
  fetch: globalThis.fetch,
  secretsManagerClient,
  GetSecretValueCommand,
  dynamoDocumentClient,
  dynamoCommands: { GetCommand, PutCommand, DeleteCommand },
  lambdaClient,
  InvokeCommand,
});
