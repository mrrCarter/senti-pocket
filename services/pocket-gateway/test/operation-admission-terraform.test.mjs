import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const MODULE = join(
  dirname(fileURLToPath(import.meta.url)),
  '..',
  'infra',
  'terraform',
  'operation-admission',
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

function compact(value) {
  return value.replace(/\s+/g, ' ').trim();
}

function declaration(value, header) {
  const start = value.indexOf(`${header} {`);
  assert.notEqual(start, -1, `missing Terraform declaration: ${header}`);
  const match = value.slice(start).match(
    /^[\s\S]*?(?=\n(?:terraform|provider|locals|resource|data|variable|output|module|check|moved|import)\b|$)/,
  );
  assert.ok(match, `could not isolate Terraform declaration: ${header}`);
  return match[0];
}

test('Terraform invokes the exact gateway version for a fixed non-secret runtime attestation', async () => {
  const [gateway, locals, versions, corpus] = await Promise.all([
    source('gateway.tf'),
    source('locals.tf'),
    source('versions.tf'),
    terraformCorpus(),
  ]);

  assert.match(gateway, /data "aws_lambda_invocation" "gateway_version_attestation"/);
  assert.match(gateway, /function_name\s*=\s*var\.gateway_lambda_function_name/);
  assert.match(gateway, /qualifier\s*=\s*var\.gateway_lambda_version/);
  assert.match(
    gateway,
    /input\s*=\s*jsonencode\(\{\s*schema\s*=\s*local\.gateway_attestation_request_schema\s*\}\)/,
  );
  assert.match(
    locals,
    /gateway_attestation_request_schema\s*=\s*"senti\.gateway\.operation-admission-attestation\.request\.v1"/,
  );
  assert.match(
    locals,
    /gateway_attestation_response_schema\s*=\s*"senti\.gateway\.operation-admission-attestation\.response\.v1"/,
  );
  assert.match(
    locals,
    /gateway_admission_capability\s*=\s*"registry-v2-operation-admission-capable"/,
  );

  const allowlist = gateway.match(
    /toset\(keys\(jsondecode\(self\.result\)\)\)\s*==\s*toset\(\[([\s\S]*?)\]\),\s*false\)/,
  );
  assert.ok(allowlist, 'attestation must enforce an exact response-key allowlist');
  assert.deepEqual(
    [...allowlist[1].matchAll(/"([^"]+)"/g)].map((match) => match[1]),
    [
      'schema',
      'capability',
      'invoked_function_arn',
      'function_version',
      'registry_mode',
      'v1_purged',
      'client_ready',
      'outcome_ready',
      'owner_ready',
      'hmac_secret_arn',
      'hmac_secret_version_id',
      'assertion_schema',
    ],
  );

  assert.match(
    gateway,
    /try\(jsondecode\(self\.result\)\.schema,\s*""\)\s*==\s*local\.gateway_attestation_response_schema/,
  );
  assert.match(
    gateway,
    /try\(jsondecode\(self\.result\)\.capability,\s*""\)\s*==\s*local\.gateway_admission_capability/,
  );
  assert.match(
    gateway,
    /try\(jsondecode\(self\.result\)\.assertion_schema,\s*""\)\s*==\s*"senti-pocket-operation-admission-assertion-v1"/,
  );
  assert.match(
    gateway,
    /try\(jsondecode\(self\.result\)\.invoked_function_arn,\s*""\)\s*==\s*local\.gateway_version_arn/,
  );
  assert.match(
    gateway,
    /try\(jsondecode\(self\.result\)\.function_version,\s*""\)\s*==\s*var\.gateway_lambda_version/,
  );
  assert.match(
    gateway,
    /try\(jsondecode\(self\.result\)\.registry_mode,\s*""\)\s*==\s*"v2"/,
  );
  for (const field of ['v1_purged', 'client_ready', 'outcome_ready', 'owner_ready']) {
    assert.match(
      gateway,
      new RegExp(`try\\(jsondecode\\(self\\.result\\)\\.${field},\\s*""\\)\\s*==\\s*"1"`),
    );
  }
  assert.match(
    gateway,
    /try\(jsondecode\(self\.result\)\.hmac_secret_arn,\s*""\)\s*==\s*var\.gateway_registry_hmac_secret_arn/,
  );
  assert.match(
    gateway,
    /try\(jsondecode\(self\.result\)\.hmac_secret_version_id,\s*""\)\s*==\s*var\.gateway_registry_hmac_secret_version_id/,
  );

  assert.doesNotMatch(
    corpus,
    /\bdata\s+"external"\b|\bdata\s+"aws_lambda_function"\b|\bprovisioner\s+"local-exec"\b|\bprogram\s*=/,
  );
  assert.doesNotMatch(versions, /hashicorp\/external/);
  assert.doesNotMatch(
    gateway,
    /\b(?:functionArn|codeSha256|descriptionManifest|secretArn|secretVersion|v1Purged|clientReady|outcomeReady|admissionReady|ownerReady)\b|\badmission_ready\b|\bcode_sha256\b|\bdescription_manifest\b/,
  );
});

test('Terraform records independent gateway artifact evidence outside runtime attestation', async () => {
  const [gateway, locals, outputs, variables, corpus] = await Promise.all([
    source('gateway.tf'),
    source('locals.tf'),
    source('outputs.tf'),
    source('variables.tf'),
    terraformCorpus(),
  ]);

  const manifest = locals.match(
    /gateway_release_manifest\s*=\s*var\.enabled\s*\?\s*\{([\s\S]*?)\}\s*:\s*null/,
  );
  assert.ok(manifest, 'gateway release evidence must be a structured manifest');
  assert.deepEqual(
    [...manifest[1].matchAll(/^\s*([a-z0-9_]+)\s*=/gm)].map((match) => match[1]),
    [
      'schema',
      'artifact_sha256',
      'attestation_sha256',
      'capability',
      'function_version',
      'hmac_secret_arn',
      'hmac_secret_version_id',
    ],
  );
  assert.match(manifest[0], /schema\s*=\s*"senti\.pocket\.gateway-release-evidence\.v1"/);
  assert.match(manifest[0], /artifact_sha256\s*=\s*var\.gateway_release_artifact_sha256/);
  assert.match(
    manifest[0],
    /attestation_sha256\s*=\s*sha256\(jsonencode\(local\.gateway_version_attestation\)\)/,
  );
  assert.match(manifest[0], /function_version\s*=\s*local\.gateway_version_attestation\.function_version/);
  assert.match(
    declaration(outputs, 'output "gateway_release_manifest"'),
    /value\s*=\s*local\.gateway_release_manifest/,
  );

  const releaseDigest = declaration(variables, 'variable "gateway_release_artifact_sha256"');
  assert.match(releaseDigest, /independently verified release evidence/);
  assert.ok(
    releaseDigest.includes(
      'regex("^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$", var.gateway_release_artifact_sha256)',
    ),
  );
  assert.doesNotMatch(gateway, /gateway_release_artifact_sha256|artifact_sha256|code_sha256/);
  assert.doesNotMatch(
    corpus,
    /\bgateway_lambda_code_sha256\b|\bgateway_description_manifest\b|\bgateway_attestation_schema\b|\badmission_ready\b/,
  );
});

test('Terraform routes and API permissions target only numeric published Lambda versions', async () => {
  const [api, lambda, locals, variables, corpus] = await Promise.all([
    source('api.tf'),
    source('lambda.tf'),
    source('locals.tf'),
    source('variables.tf'),
    terraformCorpus(),
  ]);

  const admissionIntegration = compact(
    declaration(api, 'resource "aws_apigatewayv2_integration" "admission"'),
  );
  const gatewayIntegration = compact(
    declaration(api, 'resource "aws_apigatewayv2_integration" "gateway"'),
  );
  const admissionPermission = compact(
    declaration(api, 'resource "aws_lambda_permission" "admission_from_api"'),
  );
  const gatewayPermission = compact(
    declaration(api, 'resource "aws_lambda_permission" "gateway_from_api"'),
  );

  assert.match(
    admissionIntegration,
    /integration_uri = aws_lambda_function\.admission\[0\]\.qualified_invoke_arn/,
  );
  assert.match(admissionIntegration, /depends_on = \[aws_lambda_permission\.admission_from_api\]/);
  assert.match(gatewayIntegration, /integration_uri = local\.gateway_version_invoke_arn/);
  assert.match(gatewayIntegration, /depends_on = \[aws_lambda_permission\.gateway_from_api\]/);
  assert.match(
    locals,
    /gateway_version_invoke_arn\s*=\s*var\.enabled\s*\?\s*"arn:\$\{var\.aws_partition\}:apigateway:\$\{var\.aws_region\}:lambda:path\/2015-03-31\/functions\/\$\{local\.gateway_version_attestation\.invoked_function_arn\}\/invocations"\s*:\s*null/,
  );

  assert.match(admissionPermission, /function_name = aws_lambda_function\.admission\[0\]\.function_name/);
  assert.match(admissionPermission, /qualifier = aws_lambda_function\.admission\[0\]\.version/);
  assert.match(gatewayPermission, /function_name = var\.gateway_lambda_function_name/);
  assert.match(gatewayPermission, /qualifier = local\.gateway_version_attestation\.function_version/);
  for (const permission of [admissionPermission, gatewayPermission]) {
    assert.match(
      permission,
      /source_arn = format\( "%s\/%s\/%s%s", aws_apigatewayv2_api\.operation_admission\[0\]\.execution_arn, var\.api_stage_name, split\(" ", each\.key\)\[0\], split\(" ", each\.key\)\[1\], \)/,
    );
    assert.match(permission, /lifecycle \{ create_before_destroy = true \}/);
  }

  assert.match(lambda, /publish\s*=\s*true/);
  assert.match(
    declaration(variables, 'variable "gateway_lambda_version"'),
    /regex\("\^\[1-9\]\[0-9\]\*\$",\s*var\.gateway_lambda_version\)/,
  );
  assert.match(
    compact(declaration(api, 'resource "aws_apigatewayv2_route" "protected"')),
    /target = "integrations\/\$\{aws_apigatewayv2_integration\.admission\[0\]\.id\}"/,
  );
  assert.match(
    compact(declaration(api, 'resource "aws_apigatewayv2_route" "gateway"')),
    /target = "integrations\/\$\{aws_apigatewayv2_integration\.gateway\[0\]\.id\}"/,
  );
  assert.doesNotMatch(corpus, /\baws_lambda_alias\b/);
  assert.doesNotMatch(api, /integrationErrorMessage|function_url|"\*"/iu);
});

test('Terraform admission runtime consumes and may invoke only the attested gateway version', async () => {
  const [lambda, iam] = await Promise.all([
    source('lambda.tf').then(compact),
    source('iam.tf').then(compact),
  ]);

  assert.match(
    lambda,
    /GATEWAY_LAMBDA_VERSION_ARN = local\.gateway_version_attestation\.invoked_function_arn/,
  );
  assert.match(
    lambda,
    /GATEWAY_LAMBDA_VERSION = local\.gateway_version_attestation\.function_version/,
  );
  assert.doesNotMatch(lambda, /GATEWAY_LAMBDA_ALIAS_ARN|GATEWAY_LAMBDA_VERSION = var\.gateway_lambda_version/);
  assert.match(
    iam,
    /Sid = "InvokeImmutableGatewayVersionOnly".*?Action = \["lambda:InvokeFunction"\].*?Resource = local\.gateway_version_attestation\.invoked_function_arn/,
  );
  assert.equal((iam.match(/"lambda:InvokeFunction"/g) || []).length, 1);
  assert.doesNotMatch(iam, /InvokeQualifiedGatewayAliasOnly|Resource = local\.gateway_version_arn/);
  assert.match(
    iam,
    /Sid = "ReadPinnedRegistryHmacVersion".*?"secretsmanager:VersionId" = var\.registry_hmac_secret_version_id/,
  );
});

test('Terraform owns and enforces one AWS Signer publisher for every enabled production admission Lambda', async () => {
  const [signing, lambda, locals, variables] = await Promise.all([
    source('signing.tf'),
    source('lambda.tf'),
    source('locals.tf'),
    source('variables.tf'),
  ]);

  assert.match(
    locals,
    /production_admission_enabled\s*=\s*var\.enabled\s*&&\s*var\.environment\s*==\s*"prod"/,
  );
  const profile = compact(
    declaration(signing, 'data "aws_signer_signing_profile" "admission"'),
  );
  assert.match(profile, /count = local\.production_admission_enabled \? 1 : 0/);
  assert.match(profile, /name = var\.admission_signing_profile_name/);
  assert.match(profile, /self\.platform_id == "AWSLambda-SHA384-ECDSA"/);
  assert.match(profile, /self\.status == "Active"/);
  assert.match(profile, /self\.arn == join\("", \[/);
  assert.match(profile, /can\(regex\("\^\[A-Za-z0-9\]\{10\}\$", self\.version\)\)/);
  assert.match(profile, /self\.version_arn == "\$\{self\.arn\}\/\$\{self\.version\}"/);

  const config = declaration(signing, 'resource "aws_lambda_code_signing_config" "admission"');
  const allowedPublishers = config.match(/allowed_publishers\s*\{([\s\S]*?)\}/);
  assert.ok(allowedPublishers, 'code-signing config must define its allowed publishers');
  assert.equal(
    (allowedPublishers[1].match(/data\.aws_signer_signing_profile\.admission\[0\]\.version_arn/g) || [])
      .length,
    1,
  );
  assert.match(config, /count\s*=\s*local\.production_admission_enabled\s*\?\s*1\s*:\s*0/);
  assert.match(config, /length\(self\.allowed_publishers\)\s*==\s*1/);
  assert.match(
    config,
    /toset\(self\.allowed_publishers\[0\]\.signing_profile_version_arns\)[\s\S]*?toset\(\[data\.aws_signer_signing_profile\.admission\[0\]\.version_arn\]\)/,
  );
  assert.match(config, /untrusted_artifact_on_deployment\s*=\s*"Enforce"/);
  assert.match(config, /self\.policies\[0\]\.untrusted_artifact_on_deployment\s*==\s*"Enforce"/);

  assert.match(
    lambda,
    /code_signing_config_arn\s*=\s*local\.production_admission_enabled\s*\?\s*aws_lambda_code_signing_config\.admission\[0\]\.arn\s*:\s*null/,
  );
  assert.match(lambda, /source_code_hash\s*=\s*var\.admission_package_sha256/);
  assert.match(lambda, /postcondition\s*\{\s*condition\s*=\s*self\.code_sha256\s*==\s*var\.admission_package_sha256/);
  assert.doesNotMatch(lambda, /gateway_release_artifact_sha256/);

  const signingProfileName = compact(
    declaration(variables, 'variable "admission_signing_profile_name"'),
  );
  assert.match(
    signingProfileName,
    /var\.admission_signing_profile_name == "" && !\(var\.enabled && var\.environment == "prod"\)/,
  );
  assert.doesNotMatch(variables, /variable "code_signing_config_arn"/);
});

test('Terraform proof gates and secret validators fail closed before public cutover', async () => {
  const [api, variables] = await Promise.all([
    source('api.tf'),
    source('variables.tf'),
  ]);

  for (const name of ['dark_proof_sha256', 'mapped_proof_sha256']) {
    const proof = declaration(variables, `variable "${name}"`);
    assert.ok(proof.includes(`regex("^[0-9a-f]{64}$", var.${name})`));
  }

  const mapping = compact(
    declaration(api, 'resource "aws_apigatewayv2_api_mapping" "operation_admission"'),
  );
  assert.match(mapping, /count = var\.enabled && var\.traffic_enabled \? 1 : 0/);
  assert.match(mapping, /can\(regex\("\^\[0-9a-f\]\{64\}\$", var\.dark_proof_sha256\)\)/);
  assert.doesNotMatch(mapping, /mapped_proof_sha256/);

  const dns = compact(
    declaration(api, 'resource "aws_route53_record" "operation_admission"'),
  );
  assert.match(dns, /count = var\.enabled && var\.traffic_enabled && var\.publish_dns \? 1 : 0/);
  assert.match(dns, /can\(regex\("\^\[0-9a-f\]\{64\}\$", var\.dark_proof_sha256\)\)/);
  assert.match(dns, /can\(regex\("\^\[0-9a-f\]\{64\}\$", var\.mapped_proof_sha256\)\)/);

  const secretArnPattern =
    '^arn:(aws|aws-cn|aws-us-gov):secretsmanager:[a-z0-9-]{1,32}:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]{1,512}-[A-Za-z0-9]{6}$';
  for (const name of ['registry_hmac_secret_arn', 'gateway_registry_hmac_secret_arn']) {
    const secret = declaration(variables, `variable "${name}"`);
    assert.ok(secret.includes(`regex("${secretArnPattern}", var.${name})`));
    assert.match(secret, /wildcard-free Secrets Manager secret ARN/);
    assert.doesNotMatch(secret, /\*/);
  }
});

test('Terraform source binds retained state and logs to a dedicated CMK and documents the remote-state CMK', async () => {
  const [storage, logging, versions, variables, deploy] = await Promise.all([
    source('storage.tf').then(compact),
    source('logging.tf').then(compact),
    source('versions.tf').then(compact),
    source('variables.tf').then(compact),
    readFile(join(MODULE, '..', '..', '..', 'DEPLOY.md'), 'utf8').then(compact),
  ]);

  assert.match(storage, /deletion_protection_enabled = var\.table_deletion_protection_enabled/);
  assert.match(storage, /kms_key_arn = aws_kms_key\.operation_admission\[0\]\.arn/);
  assert.match(storage, /lifecycle \{ prevent_destroy = true \}/);
  assert.match(logging, /kms_key_id = aws_kms_key\.operation_admission\[0\]\.arn/);
  assert.equal((logging.match(/skip_destroy = true/g) || []).length, 2);
  assert.equal((logging.match(/lifecycle \{ prevent_destroy = true \}/g) || []).length, 2);
  assert.match(versions, /backend "s3" \{ encrypt = true \}/);
  assert.match(versions, /Production initialization supplies bucket, key, region, kms_key_id, and dynamodb_table/);
  assert.match(versions, /version = "= 5\.80\.0"/);
  assert.match(
    variables,
    /variable "admission_package_s3_object_version".*?lower\(var\.admission_package_s3_object_version\) != "null"/,
  );
  assert.match(
    deploy,
    /account-owned, private, versioned bucket using SSE-KMS, TLS-only bucket policy, least-privileged state access, and a dedicated DynamoDB lock table/,
  );
  for (const setting of ['bucket', 'key', 'region', 'kms_key_id', 'dynamodb_table']) {
    assert.match(deploy, new RegExp(`-backend-config="${setting}=`));
  }
  assert.match(deploy, /-backend-config="kms_key_id=<state-CMK-ARN>"/);
  assert.match(
    deploy,
    /backend CMK must be pre-existing and distinct from the module-managed admission CMK/,
  );
  for (const action of ['kms:Encrypt', 'kms:Decrypt', 'kms:GenerateDataKey']) {
    assert.match(deploy, new RegExp(action));
  }
});
