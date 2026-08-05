import { GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import {
  DeleteCommand,
  GetCommand,
  PutCommand,
  TransactWriteCommand,
} from '@aws-sdk/lib-dynamodb';

import { createGatewayAwsClients } from './aws-clients.mjs';
import { createGatewayBootstrap } from './bootstrap.mjs';

const { secretsManagerClient, dynamoDocumentClient } = createGatewayAwsClients();

export const handler = createGatewayBootstrap({
  env: process.env,
  fetch: globalThis.fetch,
  secretsManagerClient,
  GetSecretValueCommand,
  dynamoDocumentClient,
  dynamoCommands: { GetCommand, PutCommand, DeleteCommand, TransactWriteCommand },
});
