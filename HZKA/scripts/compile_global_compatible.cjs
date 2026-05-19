#!/usr/bin/env node
/**
 * Compile global audit contracts for the geth image used in the VM experiment.
 * Targeting "paris" avoids Solidity bytecode that contains PUSH0.
 */

const fs = require('fs');
const path = require('path');
const solc = require('solc');

const PROJECT_DIR = path.join(__dirname, '..');
const OUT_DIR = process.env.GLOBAL_BUILD_DIR || path.join(PROJECT_DIR, 'build_global');

const ENTRY_SOURCES = [
  'contracts/audit_chain/ReputationRegistry.sol',
  'contracts/audit_chain/ClusterManager.sol',
  'contracts/audit_chain/AuditContractV2.sol',
  'contracts/libraries/Groth16Verifier.sol',
];

function findImport(importPath) {
  const candidates = [
    importPath,
    path.join('contracts', importPath),
    path.normalize(path.join('contracts/audit_chain', importPath)),
    path.normalize(path.join('contracts/libraries', importPath)),
  ];

  for (const candidate of candidates) {
    const fullPath = path.join(PROJECT_DIR, candidate);
    if (fs.existsSync(fullPath)) {
      return { contents: fs.readFileSync(fullPath, 'utf8') };
    }
  }

  return { error: `Import not found: ${importPath}` };
}

function main() {
  const sources = {};
  for (const sourcePath of ENTRY_SOURCES) {
    sources[sourcePath] = {
      content: fs.readFileSync(path.join(PROJECT_DIR, sourcePath), 'utf8'),
    };
  }

  const input = {
    language: 'Solidity',
    sources,
    settings: {
      optimizer: { enabled: true, runs: 200 },
      evmVersion: 'paris',
      outputSelection: {
        '*': {
          '*': ['abi', 'evm.bytecode.object'],
        },
      },
    },
  };

  const output = JSON.parse(solc.compile(JSON.stringify(input), { import: findImport }));
  const errors = output.errors || [];
  const fatalErrors = errors.filter((item) => item.severity === 'error');

  for (const item of errors) {
    const prefix = item.severity === 'error' ? 'ERROR' : 'WARN';
    console.error(`[${prefix}] ${item.formattedMessage.trim()}`);
  }

  if (fatalErrors.length > 0) {
    throw new Error(`Solidity compile failed with ${fatalErrors.length} error(s)`);
  }

  fs.mkdirSync(OUT_DIR, { recursive: true });

  const wanted = {
    ReputationRegistry: 'contracts/audit_chain/ReputationRegistry.sol',
    ClusterManager: 'contracts/audit_chain/ClusterManager.sol',
    AuditContractV2: 'contracts/audit_chain/AuditContractV2.sol',
  };

  for (const [contractName, sourcePath] of Object.entries(wanted)) {
    const contract = output.contracts?.[sourcePath]?.[contractName];
    if (!contract?.abi || !contract?.evm?.bytecode?.object) {
      throw new Error(`Missing compiler output for ${contractName}`);
    }

    fs.writeFileSync(
      path.join(OUT_DIR, `${contractName}.abi`),
      JSON.stringify(contract.abi, null, 2),
    );
    fs.writeFileSync(path.join(OUT_DIR, `${contractName}.bin`), contract.evm.bytecode.object);
    console.log(`  Wrote ${path.relative(PROJECT_DIR, path.join(OUT_DIR, `${contractName}.bin`))}`);
  }

  console.log(`Compatible global audit build saved to ${path.relative(PROJECT_DIR, OUT_DIR)}`);
}

main();
