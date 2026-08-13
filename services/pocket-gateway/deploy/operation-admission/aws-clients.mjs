import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { LambdaClient } from '@aws-sdk/client-lambda';
import { SecretsManagerClient } from '@aws-sdk/client-secrets-manager';
import { DynamoDBDocumentClient } from '@aws-sdk/lib-dynamodb';
import { NodeHttpHandler } from '@smithy/node-http-handler';

export const SHORT_AWS_TRANSPORT_OPTIONS = Object.freeze({
  connectionTimeout: 750,
  requestTimeout: 3_000,
  socketTimeout: 3_000,
  throwOnRequestTimeout: true,
});

export const GATEWAY_INVOKE_TRANSPORT_OPTIONS = Object.freeze({
  connectionTimeout: 750,
  requestTimeout: 15_000,
  socketTimeout: 15_000,
  throwOnRequestTimeout: true,
});

function clientOptions(transportOptions) {
  return {
    // Admission/gateway replay semantics own every retry. Retrying an outcome-ambiguous conditional write or
    // synchronous Lambda invocation inside the SDK can double-charge a quota lane or execute the gateway twice.
    maxAttempts: 1,
    requestHandler: new NodeHttpHandler(transportOptions),
  };
}

export function createOperationAdmissionAwsClients() {
  const rawDynamoClient = new DynamoDBClient(clientOptions(SHORT_AWS_TRANSPORT_OPTIONS));
  const secretsManagerClient = new SecretsManagerClient(clientOptions(SHORT_AWS_TRANSPORT_OPTIONS));
  const lambdaClient = new LambdaClient(clientOptions(GATEWAY_INVOKE_TRANSPORT_OPTIONS));
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
    lambdaClient,
    destroy() {
      dynamoDocumentClient.destroy();
      secretsManagerClient.destroy();
      lambdaClient.destroy();
    },
  });
}
