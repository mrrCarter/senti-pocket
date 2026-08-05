// Strict AWS SDK v3 adapter for synchronous invocation of the private gateway Lambda.
//
// The SDK client and InvokeCommand are injected so this module stays dependency-free. Only an immutable numeric
// version ARN is accepted: a named alias could drift before invocation and execute un-attested code before its
// ExecutedVersion response is available to validate.

import { TextDecoder } from 'node:util';

export const LAMBDA_INVOKE_MAX_REQUEST_BYTES = 512 * 1024;
export const LAMBDA_INVOKE_MAX_RESPONSE_BYTES = 256 * 1024;

const QUALIFIED_VERSION_ARN_RE =
  /^arn:(?:aws|aws-cn|aws-us-gov):lambda:[a-z0-9-]+:[0-9]{12}:function:[A-Za-z0-9_-]+:([1-9][0-9]{0,19})$/;
const EXECUTED_VERSION_RE = /^[1-9][0-9]{0,19}$/;
const UTF8 = new TextDecoder('utf-8', { fatal: true });

export class LambdaInvokeAdapterError extends Error {
  constructor() {
    super('private gateway invocation unavailable');
    this.name = 'LambdaInvokeAdapterError';
    this.code = 'gateway-invoke-unavailable';
  }
}

function configurationError(message) {
  const error = new Error(message);
  error.name = 'LambdaInvokeAdapterConfigurationError';
  error.code = 'gateway-invoke-configuration-invalid';
  return error;
}

function positiveByteLimit(value, name) {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw configurationError(`${name} must be a positive safe integer`);
  }
  return value;
}

function invokeError() {
  // Intentionally omit a cause: SDK errors and malformed Payload/FunctionError/LogResult values can contain customer
  // bearer/body data. Callers receive one stable typed failure and the proxy maps it to its generic 503 envelope.
  return new LambdaInvokeAdapterError();
}

function payloadBytes(payload) {
  if (!ArrayBuffer.isView(payload)) throw invokeError();
  return new Uint8Array(payload.buffer, payload.byteOffset, payload.byteLength);
}

/**
 * @param {object} options
 * @param {{send:Function}} options.client injected AWS SDK v3 LambdaClient
 * @param {Function} options.InvokeCommand injected AWS SDK v3 InvokeCommand class
 * @param {string} options.gatewayVersionArn fully qualified immutable numeric Lambda version ARN
 * @param {string} options.expectedExecutedVersion exact published numeric version in gatewayVersionArn
 * @param {number} [options.maxRequestBytes]
 * @param {number} [options.maxResponseBytes]
 * @returns {(event:object)=>Promise<object>} private gateway invoker for createOperationAdmissionProxy
 */
export function createLambdaInvokeAdapter({
  client,
  InvokeCommand,
  gatewayVersionArn,
  expectedExecutedVersion,
  maxRequestBytes = LAMBDA_INVOKE_MAX_REQUEST_BYTES,
  maxResponseBytes = LAMBDA_INVOKE_MAX_RESPONSE_BYTES,
} = {}) {
  if (!client || typeof client.send !== 'function') {
    throw configurationError('Lambda invoke adapter requires a v3 client with send');
  }
  if (typeof InvokeCommand !== 'function') {
    throw configurationError('Lambda invoke adapter requires injected InvokeCommand');
  }
  const versionArnMatch = typeof gatewayVersionArn === 'string'
    ? QUALIFIED_VERSION_ARN_RE.exec(gatewayVersionArn)
    : null;
  if (!versionArnMatch) {
    throw configurationError('gatewayVersionArn must be a qualified numeric Lambda version ARN');
  }
  if (typeof expectedExecutedVersion !== 'string' || !EXECUTED_VERSION_RE.test(expectedExecutedVersion)) {
    throw configurationError('expectedExecutedVersion must be a positive published numeric Lambda version');
  }
  if (versionArnMatch[1] !== expectedExecutedVersion) {
    throw configurationError('gatewayVersionArn must end with expectedExecutedVersion');
  }
  const requestLimit = positiveByteLimit(maxRequestBytes, 'maxRequestBytes');
  const responseLimit = positiveByteLimit(maxResponseBytes, 'maxResponseBytes');

  return async function invokeGateway(event) {
    let command;
    try {
      const serialized = JSON.stringify(event);
      if (typeof serialized !== 'string' || Buffer.byteLength(serialized, 'utf8') > requestLimit) {
        throw invokeError();
      }
      command = new InvokeCommand({
        FunctionName: gatewayVersionArn,
        InvocationType: 'RequestResponse',
        LogType: 'None',
        Payload: Buffer.from(serialized, 'utf8'),
      });
    } catch {
      throw invokeError();
    }

    let response;
    try {
      response = await client.send(command);
    } catch {
      throw invokeError();
    }

    try {
      if (!response || typeof response !== 'object' || Array.isArray(response)) throw invokeError();
      if (response.StatusCode !== 200) throw invokeError();
      if (Object.hasOwn(response, 'FunctionError') || Object.hasOwn(response, 'LogResult')) throw invokeError();
      if (!Object.hasOwn(response, 'ExecutedVersion')) throw invokeError();
      const executedVersion = response.ExecutedVersion;
      if (executedVersion !== expectedExecutedVersion) throw invokeError();

      const bytes = payloadBytes(response.Payload);
      if (bytes.byteLength === 0 || bytes.byteLength > responseLimit) throw invokeError();
      const decoded = UTF8.decode(bytes);
      const result = JSON.parse(decoded);
      if (!result || typeof result !== 'object' || Array.isArray(result)) throw invokeError();
      return result;
    } catch {
      throw invokeError();
    }
  };
}
