import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { SecretsManagerClient } from '@aws-sdk/client-secrets-manager';
import { DynamoDBDocumentClient } from '@aws-sdk/lib-dynamodb';
import { NodeHttpHandler } from '@smithy/node-http-handler';

export const GATEWAY_AWS_TRANSPORT_OPTIONS = Object.freeze({
  connectionTimeout: 750,
  requestTimeout: 3_000,
  socketTimeout: 3_000,
  throwOnRequestTimeout: true,
});

function clientOptions() {
  return {
    // Gateway persistence and APNs delivery own their own replay semantics. An SDK retry after an outcome-ambiguous
    // write could repeat a conditional state transition, so every AWS boundary is one explicit attempt.
    maxAttempts: 1,
    requestHandler: new NodeHttpHandler(GATEWAY_AWS_TRANSPORT_OPTIONS),
  };
}

export function createGatewayAwsClients() {
  const rawDynamoClient = new DynamoDBClient(clientOptions());
  const secretsManagerClient = new SecretsManagerClient(clientOptions());
  const dynamoDocumentClient = DynamoDBDocumentClient.from(rawDynamoClient, {
    marshallOptions: {
      convertClassInstanceToMap: false,
      removeUndefinedValues: false,
    },
  });

  return Object.freeze({
    rawDynamoClient,
    dynamoDocumentClient,
    secretsManagerClient,
    destroy() {
      dynamoDocumentClient.destroy();
      secretsManagerClient.destroy();
    },
  });
}
