import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const MODULE = join(TEST_DIR, '..', 'infra', 'terraform', 'gateway');
const WORKFLOW = join(
  TEST_DIR,
  '..',
  '..',
  '..',
  '.github',
  'workflows',
  'pocket-gateway-operation-admission.yml',
);

async function source(name) {
  return readFile(join(MODULE, name), 'utf8');
}

async function terraformCorpus() {
  const names = (await readdir(MODULE))
    .filter((name) => name.endsWith('.tf'))
    .sort();
  return (await Promise.all(names.map(source))).join('\n');
}

function variableBlock(value, name) {
  const start = value.indexOf(`variable "${name}" {`);
  assert.notEqual(start, -1, `missing Terraform variable ${name}`);
  const match = value.slice(start).match(/^[\s\S]*?(?=\nvariable "|$)/);
  assert.ok(match, `could not isolate Terraform variable ${name}`);
  return match[0];
}

test('gateway Terraform is disabled and APNs-off by default with no public or mutable surface', async () => {
  const [variables, lambda, locals, outputs, corpus] = await Promise.all([
    source('variables.tf'),
    source('lambda.tf'),
    source('locals.tf'),
    source('outputs.tf'),
    terraformCorpus(),
  ]);

  assert.match(variableBlock(variables, 'enabled'), /default\s*=\s*false/);
  assert.match(variableBlock(variables, 'apns_voip_enabled'), /default\s*=\s*false/);
  const objectVersion = variableBlock(variables, 'gateway_package_s3_object_version');
  assert.match(objectVersion, /trimspace\(var\.gateway_package_s3_object_version\)\s*==\s*var\.gateway_package_s3_object_version/);
  assert.match(objectVersion, /lower\(var\.gateway_package_s3_object_version\)\s*!=\s*"null"/);
  assert.match(lambda, /resource "aws_lambda_function" "gateway"/);
  assert.match(lambda, /count\s*=\s*var\.enabled\s*\?\s*1\s*:\s*0/);
  assert.match(lambda, /runtime\s*=\s*"nodejs22\.x"/);
  assert.match(lambda, /publish\s*=\s*true/);
  assert.match(lambda, /s3_object_version\s*=\s*var\.gateway_package_s3_object_version/);
  assert.match(lambda, /source_code_hash\s*=\s*var\.gateway_package_sha256/);
  assert.match(lambda, /reserved_concurrent_executions\s*=\s*var\.gateway_reserved_concurrency/);
  assert.doesNotMatch(locals, /AWS_LAMBDA_FUNCTION_VERSION/);

  assert.doesNotMatch(
    corpus,
    /resource\s+"(?:aws_apigateway|aws_apigatewayv2|aws_lambda_alias|aws_lambda_function_url|aws_lambda_permission|aws_route53_record)\b/,
  );
  for (const field of [
    'public_api_created',
    'lambda_function_url_created',
    'lambda_invoke_permission_created',
    'mutable_lambda_alias_created',
    'target_membership_release_proven',
  ]) {
    assert.match(outputs, new RegExp(`${field}\\s*=\\s*false`));
  }
});

test('gateway Terraform passes only immutable secret references and grants exact conditional reads', async () => {
  const [variables, locals, iam, corpus] = await Promise.all([
    source('variables.tf'),
    source('locals.tf'),
    source('iam.tf'),
    terraformCorpus(),
  ]);

  const variableNames = [...variables.matchAll(/variable "([^"]+)"/g)].map((match) => match[1]);
  const runtimePolicy = `${locals}\n${iam}`;
  const secretVariables = variableNames.filter((name) => name.includes('secret'));
  assert.deepEqual(secretVariables, [
    'signing_key_secret_arn',
    'signing_key_secret_version_id',
    'registry_hmac_secret_arn',
    'registry_hmac_secret_version_id',
    'apns_private_key_secret_arn',
    'apns_private_key_secret_version_id',
  ]);
  assert.doesNotMatch(
    variables,
    /variable "(?:.*(?:private_key|hmac|pem|secret_string|secret_value|key_bytes))"/,
  );
  assert.doesNotMatch(corpus, /DEVICE_REGISTRY_HMAC_KEY_B64\s*=/);
  assert.doesNotMatch(corpus, /APNS_PRIVATE_KEY\s*=/);

  assert.equal((locals.match(/"secretsmanager:VersionId"/g) || []).length, 3);
  assert.equal((locals.match(/"kms:EncryptionContext:SecretARN"/g) || []).length, 3);
  assert.equal((locals.match(/"kms:ViaService"/g) || []).length, 3);
  assert.match(locals, /local\.registry_v2_enabled\s*\?\s*\[\{/);
  assert.match(locals, /local\.apns_enabled\s*\?\s*\[\{/);
  assert.match(locals, /local\.apns_enabled\s*\?\s*\{[\s\S]*?APNS_PRIVATE_KEY_SECRET_ARN/);

  for (const action of ['dynamodb:DeleteItem', 'dynamodb:GetItem', 'dynamodb:PutItem']) {
    assert.match(runtimePolicy, new RegExp(`"${action}"`));
  }
  assert.doesNotMatch(runtimePolicy, /dynamodb:(?:Batch|Query|Scan|UpdateItem)/);
  assert.match(runtimePolicy, /Resource\s*=\s*try\(aws_dynamodb_table\.gateway\[0\]\.arn,\s*""\)/);
  assert.doesNotMatch(runtimePolicy, /secretsmanager:\*/);
});

test('gateway Terraform retains encrypted state and enforces exact production signing', async () => {
  const [kms, storage, logging, signing, lambda, tests] = await Promise.all([
    source('kms.tf'),
    source('storage.tf'),
    source('logging.tf'),
    source('signing.tf'),
    source('lambda.tf'),
    readFile(join(MODULE, 'tests', 'topology.tftest.hcl'), 'utf8'),
  ]);

  assert.match(kms, /enable_key_rotation\s*=\s*true/);
  assert.match(kms, /lifecycle\s*\{\s*prevent_destroy\s*=\s*true/);
  assert.match(storage, /billing_mode\s*=\s*"PAY_PER_REQUEST"/);
  assert.match(storage, /deletion_protection_enabled\s*=\s*var\.table_deletion_protection_enabled/);
  assert.match(storage, /ttl\s*\{[\s\S]*?attribute_name\s*=\s*"ttl"[\s\S]*?enabled\s*=\s*true/);
  assert.match(storage, /point_in_time_recovery\s*\{\s*enabled\s*=\s*true/);
  assert.match(storage, /kms_key_arn\s*=\s*aws_kms_key\.gateway\[0\]\.arn/);
  assert.match(logging, /kms_key_id\s*=\s*aws_kms_key\.gateway\[0\]\.arn/);
  assert.match(logging, /skip_destroy\s*=\s*true/);

  assert.match(signing, /platform_id\s*==\s*"AWSLambda-SHA384-ECDSA"/);
  assert.match(signing, /status\s*==\s*"Active"/);
  assert.match(signing, /signing_profile_version_arns\s*=\s*\[\s*data\.aws_signer_signing_profile\.gateway\[0\]\.version_arn/);
  assert.match(signing, /untrusted_artifact_on_deployment\s*=\s*"Enforce"/);
  assert.match(lambda, /self\.code_sha256\s*==\s*var\.gateway_package_sha256/);
  assert.match(lambda, /regex\("\^\[1-9\]\[0-9\]\*\$",\s*self\.version\)/);

  for (const run of [
    'disabled_by_default',
    'registry_v1_apns_off_is_private_and_minimal',
    'registry_v2_apns_on_adds_only_exact_pinned_authority',
    'production_enforces_one_signer',
    'registry_v2_refuses_unproven_cutover',
    'artifact_refuses_unversioned_s3_marker',
    'artifact_refuses_whitespace_object_version',
    'gateway_refuses_non_origin_public_url',
    'apns_refuses_missing_secret_version_pin',
  ]) {
    assert.match(tests, new RegExp(`run "${run}"`));
  }
});

test('deployment CI verifies both locked artifacts and both Terraform modules without deploy authority', async () => {
  const workflow = await readFile(WORKFLOW, 'utf8');

  assert.match(workflow, /permissions:\s*\n\s+contents: read/);
  assert.doesNotMatch(workflow, /id-token:\s*write|aws-actions\/configure-aws-credentials/);
  for (const directory of [
    'services/pocket-gateway/deploy/gateway',
    'services/pocket-gateway/deploy/operation-admission',
    'services/pocket-gateway/infra/terraform/gateway',
    'services/pocket-gateway/infra/terraform/operation-admission',
  ]) {
    assert.match(workflow, new RegExp(directory.replaceAll('/', '\\/')));
  }
  assert.equal((workflow.match(/npm ci/g) || []).length, 2);
  assert.equal((workflow.match(/npm audit --audit-level=low/g) || []).length, 2);
  assert.equal((workflow.match(/npm run package/g) || []).length, 4);
  assert.equal((workflow.match(/terraform test -no-color/g) || []).length, 2);
  assert.equal((workflow.match(/terraform init -backend=false -input=false -lockfile=readonly/g) || []).length, 2);
});
