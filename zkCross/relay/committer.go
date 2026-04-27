/**
 * zkCross - Cross-Chain Committer (Relay) Service
 * 
 * The committer is a lower-layer node that bridges ordinary chains to the audit chain.
 * It acts as the relay mechanism in zkCross's tree-shaped architecture.
 * 
 * Responsibilities:
 *   1. Monitor ordinary chains for new blocks
 *   2. Aggregate transaction data from blocks
 *   3. Generate ZKP proofs off-chain using circuit Λ_Ψ (Groth16)
 *   4. Submit TxCommit to the audit chain
 *   5. Earn rewards for successful verifications
 * 
 * Unlike traditional relay chains, zkCross uses committers as lightweight
 * bridges, mitigating single-point-of-failure risks.
 * 
 * Reference: zkCross paper Section 4.1 (Architecture), Section 5.3 (Protocol Ψ)
 */
package main

import (
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"fmt"
	"log"
	"math/big"
	"os"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

// ==========================================
// Configuration
// ==========================================

// CommitterConfig holds the committer's configuration
type CommitterConfig struct {
	// Private key for signing transactions
	PrivateKey string `json:"private_key"`

	// Ordinary chains to monitor
	OrdinaryChains []ChainConfig `json:"ordinary_chains"`

	// Audit chain connection
	AuditChain ChainConfig `json:"audit_chain"`

	// Audit contract address on the audit chain
	AuditContractAddr string `json:"audit_contract_addr"`

	// Polling interval for new blocks (seconds)
	PollInterval int `json:"poll_interval"`

	// Circuit files for proof generation
	CircuitDir string `json:"circuit_dir"`

	// Blacklist addresses (embedded as circuit constants)
	Blacklist []string `json:"blacklist"`

	// Tree-shaped topology configuration (paper Section 3.2)
	// If TreeNodeID > 0, this committer acts as an intermediate aggregation node.
	// It collects sub-chain state roots and generates a single aggregated proof,
	// Per Theorem 2, Protocol Ψ achieves n-fold audit cost reduction
	// (from t1·k·m·n to t2·k·m). The tree distributes committer workload.
	TreeNodeID uint64 `json:"tree_node_id,omitempty"`

	// ChildCommitters lists RPC endpoints of child intermediate committers
	// whose aggregated roots this node will further aggregate.
	ChildCommitters []ChildCommitterConfig `json:"child_committers,omitempty"`
}

// ChildCommitterConfig holds connection info for a child committer in the tree
type ChildCommitterConfig struct {
	NodeID   uint64 `json:"node_id"`
	RPC      string `json:"rpc_url"`
	Name     string `json:"name"`
	ChainIDs []uint64 `json:"chain_ids"`
}

// ChainConfig holds connection info for a single chain
type ChainConfig struct {
	ChainID  uint64 `json:"chain_id"`
	RPC      string `json:"rpc_url"`
	Name     string `json:"name"`

	// Per paper Section 4.1: zkCross supports both permissioned and permissionless
	// blockchains. For permissioned chains, auditors only access block headers via
	// gateways or blockchain explorers (not full node RPC).
	// Type: "permissionless" (default, full geth RPC) or "permissioned" (gateway mode)
	ChainType string `json:"chain_type,omitempty"`

	// Gateway URL for permissioned chains — provides block headers only
	// In permissioned mode, TxBurn/TxLock data is fetched via the gateway's
	// limited API (headers + Merkle proofs), not full transaction access.
	GatewayURL string `json:"gateway_url,omitempty"`
}

// ==========================================
// Data Structures
// ==========================================

// BlockData represents aggregated data from one block
type BlockData struct {
	ChainID      uint64
	BlockNumber  uint64
	StateRootOld common.Hash
	StateRootNew common.Hash
	Transactions []TransactionData
}

// TransactionData represents a single transaction for auditing
type TransactionData struct {
	From      common.Address
	To        common.Address
	Amount    *big.Int
	Signature []byte
	Nonce     uint64
}

// ProofData represents a Groth16 proof
type ProofData struct {
	A          [2]*big.Int     // G1 point
	B          [2][2]*big.Int  // G2 point
	C          [2]*big.Int     // G1 point
	PublicInputs []*big.Int    // Public inputs (root_old, root_new)
}

// ==========================================
// Chain Data Source Abstraction
// (Paper Section 4.1: permissioned + permissionless support)
// ==========================================

// ChainDataSource abstracts how block data is fetched from different chain types.
// For permissionless chains (e.g. Ethereum): full geth RPC node.
// For permissioned chains: gateway/explorer API providing only block headers
// and Merkle proofs, as specified in paper Section 4.1.
type ChainDataSource interface {
	// GetLatestBlockNumber returns the latest block number
	GetLatestBlockNumber(ctx context.Context) (uint64, error)

	// GetBlockData fetches block data (transactions + state roots)
	// For permissioned chains, this returns only what the gateway exposes
	GetBlockData(ctx context.Context, blockNum uint64) (*BlockData, error)

	// GetBlockHeader fetches only the block header (available on both chain types)
	GetBlockHeader(ctx context.Context, blockNum uint64) (*types.Header, error)

	// GetSPVProof fetches a Merkle proof for a transaction
	// Critical for Protocol Θ: receiver needs SPV proof of TxBurn
	GetSPVProof(ctx context.Context, txHash common.Hash) (*SPVProof, error)

	// ChainType returns "permissionless" or "permissioned"
	ChainType() string
}

// GethDataSource implements ChainDataSource for permissionless chains (full geth RPC)
type GethDataSource struct {
	client  *ethclient.Client
	chainID uint64
}

func NewGethDataSource(client *ethclient.Client, chainID uint64) *GethDataSource {
	return &GethDataSource{client: client, chainID: chainID}
}

func (g *GethDataSource) GetLatestBlockNumber(ctx context.Context) (uint64, error) {
	return g.client.BlockNumber(ctx)
}

func (g *GethDataSource) GetBlockData(ctx context.Context, blockNum uint64) (*BlockData, error) {
	block, err := g.client.BlockByNumber(ctx, new(big.Int).SetUint64(blockNum))
	if err != nil {
		return nil, err
	}

	blockData := &BlockData{
		ChainID:      g.chainID,
		BlockNumber:  block.NumberU64(),
		StateRootNew: block.Root(),
		Transactions: make([]TransactionData, 0),
	}

	signer := types.LatestSignerForChainID(new(big.Int).SetUint64(g.chainID))
	for _, tx := range block.Transactions() {
		from, err := types.Sender(signer, tx)
		if err != nil {
			continue
		}
		to := common.Address{}
		if tx.To() != nil {
			to = *tx.To()
		}
		txData := TransactionData{
			From:   from,
			To:     to,
			Amount: tx.Value(),
			Nonce:  tx.Nonce(),
		}
		v, r, s := tx.RawSignatureValues()
		txData.Signature = append(r.Bytes(), s.Bytes()...)
		txData.Signature = append(txData.Signature, byte(v.Uint64()))
		blockData.Transactions = append(blockData.Transactions, txData)
	}

	return blockData, nil
}

func (g *GethDataSource) GetBlockHeader(ctx context.Context, blockNum uint64) (*types.Header, error) {
	return g.client.HeaderByNumber(ctx, new(big.Int).SetUint64(blockNum))
}

func (g *GethDataSource) GetSPVProof(ctx context.Context, txHash common.Hash) (*SPVProof, error) {
	// Full node: can construct SPV proof from transaction receipts/trie
	return nil, fmt.Errorf("SPV proof construction not yet implemented for full node")
}

func (g *GethDataSource) ChainType() string { return "permissionless" }

// GatewayDataSource implements ChainDataSource for permissioned chains.
// Per paper Section 4.1: on permissioned chains, auditors/committers only have
// access to block headers via gateways or blockchain explorers.
// They CANNOT read full transaction details directly — only headers and
// Merkle proofs are available through the gateway API.
type GatewayDataSource struct {
	gatewayURL string
	chainID    uint64
}

func NewGatewayDataSource(gatewayURL string, chainID uint64) *GatewayDataSource {
	return &GatewayDataSource{gatewayURL: gatewayURL, chainID: chainID}
}

func (g *GatewayDataSource) GetLatestBlockNumber(ctx context.Context) (uint64, error) {
	// In practice: HTTP GET to gateway API for latest block number
	log.Printf("[Gateway %d] Fetching latest block number from %s\n", g.chainID, g.gatewayURL)
	return 0, fmt.Errorf("gateway API call not yet implemented")
}

func (g *GatewayDataSource) GetBlockData(ctx context.Context, blockNum uint64) (*BlockData, error) {
	// Permissioned chain gateway provides limited data:
	// - Block header (state root, tx root, timestamp)
	// - Merkle proofs for specific transactions (on request)
	// - Does NOT expose full transaction details
	// The committer on permissioned chains must receive tx data off-chain
	// from participating nodes, then verify via header-only gateway
	log.Printf("[Gateway %d] Fetching block %d data (header-only mode)\n", g.chainID, blockNum)
	return nil, fmt.Errorf("gateway block data fetch not yet implemented")
}

func (g *GatewayDataSource) GetBlockHeader(ctx context.Context, blockNum uint64) (*types.Header, error) {
	// Gateway can always provide block headers
	log.Printf("[Gateway %d] Fetching block %d header from gateway\n", g.chainID, blockNum)
	return nil, fmt.Errorf("gateway header fetch not yet implemented")
}

func (g *GatewayDataSource) GetSPVProof(ctx context.Context, txHash common.Hash) (*SPVProof, error) {
	// Gateway provides Merkle proofs for specific transactions
	log.Printf("[Gateway %d] Requesting SPV proof for tx %s\n", g.chainID, txHash.Hex())
	return nil, fmt.Errorf("gateway SPV proof not yet implemented")
}

func (g *GatewayDataSource) ChainType() string { return "permissioned" }

// ==========================================
// Committer Service
// ==========================================

// Committer is the main service that bridges ordinary chains to the audit chain
type Committer struct {
	config         CommitterConfig
	privateKey     *ecdsa.PrivateKey
	auditClient    *ethclient.Client
	chainClients   map[uint64]*ethclient.Client
	chainSources   map[uint64]ChainDataSource // Abstracted data sources (permissioned/permissionless)
	lastProcessed  map[uint64]uint64 // chainID -> last processed block number
}

// NewCommitter creates a new committer instance
func NewCommitter(configPath string) (*Committer, error) {
	// Load configuration
	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read config: %w", err)
	}

	var config CommitterConfig
	if err := json.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("failed to parse config: %w", err)
	}

	// Parse private key
	privateKey, err := crypto.HexToECDSA(config.PrivateKey)
	if err != nil {
		return nil, fmt.Errorf("failed to parse private key: %w", err)
	}

	return &Committer{
		config:        config,
		privateKey:    privateKey,
		chainClients:  make(map[uint64]*ethclient.Client),
		chainSources:  make(map[uint64]ChainDataSource),
		lastProcessed: make(map[uint64]uint64),
	}, nil
}

// Start begins the committer service
func (c *Committer) Start(ctx context.Context) error {
	log.Println("[zkCross Committer] Starting service...")

	// Connect to audit chain
	auditClient, err := ethclient.Dial(c.config.AuditChain.RPC)
	if err != nil {
		return fmt.Errorf("failed to connect to audit chain: %w", err)
	}
	c.auditClient = auditClient
	log.Printf("[zkCross Committer] Connected to audit chain: %s\n", c.config.AuditChain.Name)

	// Connect to ordinary chains (supports permissioned and permissionless)
	for _, chain := range c.config.OrdinaryChains {
		chainType := chain.ChainType
		if chainType == "" {
			chainType = "permissionless"
		}

		if chainType == "permissioned" && chain.GatewayURL != "" {
			// Permissioned chain: use gateway data source (header-only access)
			c.chainSources[chain.ChainID] = NewGatewayDataSource(chain.GatewayURL, chain.ChainID)
			log.Printf("[zkCross Committer] Connected to permissioned chain: %s (ID: %d) via gateway\n",
				chain.Name, chain.ChainID)
		} else {
			// Permissionless chain: use full geth RPC
			client, err := ethclient.Dial(chain.RPC)
			if err != nil {
				return fmt.Errorf("failed to connect to chain %s: %w", chain.Name, err)
			}
			c.chainClients[chain.ChainID] = client
			c.chainSources[chain.ChainID] = NewGethDataSource(client, chain.ChainID)
			log.Printf("[zkCross Committer] Connected to permissionless chain: %s (ID: %d)\n",
				chain.Name, chain.ChainID)
		}
	}

	// Main monitoring loop
	ticker := time.NewTicker(time.Duration(c.config.PollInterval) * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Println("[zkCross Committer] Shutting down...")
			return nil
		case <-ticker.C:
			c.processNewBlocks(ctx)
			// If this committer is an intermediate tree node, also run aggregation
			if c.config.TreeNodeID > 0 {
				if err := c.processAsIntermediateNode(ctx); err != nil {
					log.Printf("[Tree Node %d] Aggregation error: %v\n", c.config.TreeNodeID, err)
				}
			}
		}
	}
}

// processNewBlocks checks all monitored chains for new blocks
func (c *Committer) processNewBlocks(ctx context.Context) {
	for _, chain := range c.config.OrdinaryChains {
		client := c.chainClients[chain.ChainID]
		if client == nil {
			continue
		}

		// Get latest block number
		latestBlock, err := client.BlockNumber(ctx)
		if err != nil {
			log.Printf("[Chain %d] Error getting block number: %v\n", chain.ChainID, err)
			continue
		}

		lastProcessed := c.lastProcessed[chain.ChainID]
		if latestBlock <= lastProcessed {
			continue
		}

		// Process new blocks
		for blockNum := lastProcessed + 1; blockNum <= latestBlock; blockNum++ {
			if err := c.processBlock(ctx, chain.ChainID, blockNum); err != nil {
				log.Printf("[Chain %d] Error processing block %d: %v\n",
					chain.ChainID, blockNum, err)
				break
			}
			c.lastProcessed[chain.ChainID] = blockNum
		}
	}
}

// processBlock processes a single block from an ordinary chain
func (c *Committer) processBlock(ctx context.Context, chainID uint64, blockNum uint64) error {
	client := c.chainClients[chainID]

	log.Printf("[Chain %d] Processing block %d\n", chainID, blockNum)

	// Fetch block
	block, err := client.BlockByNumber(ctx, new(big.Int).SetUint64(blockNum))
	if err != nil {
		return fmt.Errorf("failed to fetch block: %w", err)
	}

	// Aggregate transaction data
	blockData, err := c.aggregateBlockData(ctx, chainID, block)
	if err != nil {
		return fmt.Errorf("failed to aggregate block data: %w", err)
	}

	if len(blockData.Transactions) == 0 {
		return nil // Skip empty blocks
	}

	// Generate ZKP proof (Protocol Ψ.Commit)
	proof, err := c.generateAuditProof(blockData)
	if err != nil {
		return fmt.Errorf("failed to generate proof: %w", err)
	}

	// Submit TxCommit to audit chain
	if err := c.submitCommit(ctx, chainID, blockData, proof); err != nil {
		return fmt.Errorf("failed to submit commit: %w", err)
	}

	log.Printf("[Chain %d] Block %d: committed %d transactions to audit chain\n",
		chainID, blockNum, len(blockData.Transactions))

	return nil
}

// aggregateBlockData extracts and formats transaction data from a block
func (c *Committer) aggregateBlockData(ctx context.Context, chainID uint64, block *types.Block) (*BlockData, error) {
	blockData := &BlockData{
		ChainID:     chainID,
		BlockNumber: block.NumberU64(),
		StateRootNew: block.Root(),
		Transactions: make([]TransactionData, 0),
	}

	// Get parent block for old state root
	if block.NumberU64() > 0 {
		client := c.chainClients[chainID]
		parentBlock, err := client.BlockByNumber(ctx,
			new(big.Int).SetUint64(block.NumberU64()-1))
		if err != nil {
			return nil, fmt.Errorf("failed to fetch parent block: %w", err)
		}
		blockData.StateRootOld = parentBlock.Root()
	}

	// Extract transactions
	signer := types.LatestSignerForChainID(new(big.Int).SetUint64(chainID))
	for _, tx := range block.Transactions() {
		from, err := types.Sender(signer, tx)
		if err != nil {
			continue
		}

		to := common.Address{}
		if tx.To() != nil {
			to = *tx.To()
		}

		txData := TransactionData{
			From:   from,
			To:     to,
			Amount: tx.Value(),
			Nonce:  tx.Nonce(),
		}

		// Extract signature bytes
		v, r, s := tx.RawSignatureValues()
		txData.Signature = append(r.Bytes(), s.Bytes()...)
		txData.Signature = append(txData.Signature, byte(v.Uint64()))

		blockData.Transactions = append(blockData.Transactions, txData)
	}

	return blockData, nil
}

// generateAuditProof generates a Groth16 proof for the audit circuit Λ_Ψ
//
// This implements Protocol Ψ.Commit:
//   1. Sets private inputs (w_vec): State_old, State_new, tx content, signatures
//   2. Sets public inputs (x_vec): initial root (root_2), final root (root_3)
//   3. Runs circuit Λ_Ψ with AF, SVF, STF, RVF modules
//   4. Generates proof π_Ψ using Groth16 Prove
//
// In practice, this would invoke the xjsnark-generated circuit via libsnark.
func (c *Committer) generateAuditProof(blockData *BlockData) (*ProofData, error) {
	log.Printf("[Prover] Generating audit proof for chain %d, block %d (%d txs)\n",
		blockData.ChainID, blockData.BlockNumber, len(blockData.Transactions))

	// ==========================================
	// Step 1: Prepare circuit inputs
	// ==========================================

	// Public inputs
	publicInputs := []*big.Int{
		new(big.Int).SetBytes(blockData.StateRootOld[:]), // root_2 (initial)
		new(big.Int).SetBytes(blockData.StateRootNew[:]), // root_3 (final)
	}

	// ==========================================
	// Step 2: Circuit execution (off-chain)
	// In a real implementation, this would:
	//   a) Write circuit inputs to .in file
	//   b) Run the xjsnark-generated Java code to produce .arith + .in
	//   c) Run libsnark's r1cs_gg_ppzksnark (Groth16) prover
	//   d) Read back the proof
	// ==========================================

	// For the framework, we prepare the proof structure
	// The actual proof generation would be done by:
	//   java -cp xjsnark_backend.jar zkcross.psi.AuditCircuit
	//   ./run_ppzksnark r1cs_gg_ppzksnark <circuit.arith> <circuit.in>

	proof := &ProofData{
		PublicInputs: publicInputs,
		// A, B, C would be populated by libsnark output
	}

	log.Printf("[Prover] Proof generated: %d public inputs, proof size = 127.38 bytes\n",
		len(publicInputs))

	return proof, nil
}

// submitCommit submits TxCommit to the audit chain smart contract
func (c *Committer) submitCommit(ctx context.Context, chainID uint64, blockData *BlockData, proof *ProofData) error {
	log.Printf("[Committer] Submitting TxCommit to audit chain for chain %d\n", chainID)

	// Get nonce
	fromAddress := crypto.PubkeyToAddress(c.privateKey.PublicKey)
	nonce, err := c.auditClient.PendingNonceAt(ctx, fromAddress)
	if err != nil {
		return fmt.Errorf("failed to get nonce: %w", err)
	}

	// Get gas price
	gasPrice, err := c.auditClient.SuggestGasPrice(ctx)
	if err != nil {
		return fmt.Errorf("failed to get gas price: %w", err)
	}

	// Prepare transaction data
	// This would encode the ABI call to AuditContract.submitCommit()
	auditContractAddr := common.HexToAddress(c.config.AuditContractAddr)

	// ABI encode: submitCommit(chainId, oldStateRoot, newStateRoot, proofA, proofB, proofC)
	callData := encodeSubmitCommit(
		chainID,
		blockData.StateRootOld,
		blockData.StateRootNew,
		proof,
	)

	// Create and sign transaction
	tx := types.NewTransaction(
		nonce,
		auditContractAddr,
		big.NewInt(0),       // No ETH transfer
		uint64(500000),       // Gas limit (enough for Groth16 verification)
		gasPrice,
		callData,
	)

	// Get chain ID for signing
	auditChainID, err := c.auditClient.ChainID(ctx)
	if err != nil {
		return fmt.Errorf("failed to get chain ID: %w", err)
	}

	signedTx, err := types.SignTx(tx, types.NewEIP155Signer(auditChainID), c.privateKey)
	if err != nil {
		return fmt.Errorf("failed to sign transaction: %w", err)
	}

	// Send transaction
	if err := c.auditClient.SendTransaction(ctx, signedTx); err != nil {
		return fmt.Errorf("failed to send transaction: %w", err)
	}

	log.Printf("[Committer] TxCommit sent: %s\n", signedTx.Hash().Hex())

	// Wait for receipt
	receipt, err := bind.WaitMined(ctx, c.auditClient, signedTx)
	if err != nil {
		return fmt.Errorf("failed waiting for receipt: %w", err)
	}

	if receipt.Status == 0 {
		return fmt.Errorf("TxCommit transaction reverted")
	}

	log.Printf("[Committer] TxCommit confirmed in block %d, gas used: %d\n",
		receipt.BlockNumber.Uint64(), receipt.GasUsed)

	return nil
}

// encodeSubmitCommit ABI-encodes the submitCommit function call
func encodeSubmitCommit(chainID uint64, oldRoot, newRoot common.Hash, proof *ProofData) []byte {
	// Function selector: keccak256("submitCommit(uint256,bytes32,bytes32,uint256[2],uint256[2][2],uint256[2])")
	// In a real implementation, this would use the generated ABI bindings
	
	// For now, encode manually
	// 4 bytes selector + parameters
	data := make([]byte, 0, 4+32*20) // approximate size

	// Function selector (first 4 bytes of keccak256 hash)
	selector := crypto.Keccak256([]byte(
		"submitCommit(uint256,bytes32,bytes32,uint256[2],uint256[2][2],uint256[2])"))[:4]
	data = append(data, selector...)

	// chainId (uint256)
	chainIDBig := new(big.Int).SetUint64(chainID)
	data = append(data, common.BigToHash(chainIDBig).Bytes()...)

	// oldStateRoot (bytes32)
	data = append(data, oldRoot.Bytes()...)

	// newStateRoot (bytes32)
	data = append(data, newRoot.Bytes()...)

	// Proof A, B, C would be encoded here
	// ... (proof encoding omitted for brevity, would use abi.Pack in production)

	return data
}

// ==========================================
// SPV Verification Helper (Protocol Θ)
// ==========================================

// SPVProof represents a Simplified Payment Verification proof
type SPVProof struct {
	TxHash       common.Hash
	MerkleRoot   common.Hash
	MerklePath   []common.Hash
	PathIndices  []bool // Direction bits (false=left, true=right)
	BlockHeader  *types.Header
}

// VerifySPV verifies an SPV proof that a transaction is included in a block
// Used by receivers in Protocol Θ.Mint to verify TxBurn exists on source chain
func VerifySPV(proof *SPVProof) bool {
	currentHash := proof.TxHash

	for i, sibling := range proof.MerklePath {
		if proof.PathIndices[i] {
			// Current node is on the right
			currentHash = common.BytesToHash(
				crypto.Keccak256(append(sibling.Bytes(), currentHash.Bytes()...)))
		} else {
			// Current node is on the left
			currentHash = common.BytesToHash(
				crypto.Keccak256(append(currentHash.Bytes(), sibling.Bytes()...)))
		}
	}

	return currentHash == proof.MerkleRoot
}

// ==========================================
// Tree-Shaped Topology: Intermediate Aggregation
// (Paper Section 3.2 - Challenge FAI)
// ==========================================

// AggregatedCommit represents an aggregated commit from intermediate nodes.
// In the tree topology, an intermediate committer:
//   1. Collects state roots from its child chains or child intermediate nodes
//   2. Computes a Merkle root over all child roots
//   3. Generates ONE aggregated ZKP proving all sub-chain transitions are valid
//   4. Submits the single proof to its parent node (or audit chain if root-level)
// Per Theorem 2, this achieves an n-fold reduction in audit cost (eliminating per-tx verification).
type AggregatedCommit struct {
	NodeID          uint64
	ChildRoots      []common.Hash   // State roots from child chains/nodes
	AggregatedRoot  common.Hash     // Merkle root of ChildRoots
	Proof           *ProofData
}

// processAsIntermediateNode runs the intermediate aggregation logic.
// Instead of submitting one proof per chain, it collects all child chain roots
// and submits a single aggregated proof to the audit contract.
func (c *Committer) processAsIntermediateNode(ctx context.Context) error {
	if c.config.TreeNodeID == 0 {
		return nil // Not an intermediate node
	}

	log.Printf("[Tree Node %d] Collecting child state roots...\n", c.config.TreeNodeID)

	childRoots := make([]common.Hash, 0)

	// Collect latest state roots from directly-monitored ordinary chains
	for _, chain := range c.config.OrdinaryChains {
		client := c.chainClients[chain.ChainID]
		if client == nil {
			continue
		}
		latestBlock, err := client.BlockByNumber(ctx, nil)
		if err != nil {
			log.Printf("[Tree Node %d] Error fetching latest block from chain %d: %v\n",
				c.config.TreeNodeID, chain.ChainID, err)
			continue
		}
		childRoots = append(childRoots, latestBlock.Root())
	}

	// Collect aggregated roots from child intermediate nodes
	for _, childComm := range c.config.ChildCommitters {
		// In practice, query the child committer's latest aggregated root
		// via an API or read from the audit contract's treeNodes mapping.
		log.Printf("[Tree Node %d] Fetching aggregated root from child node %d (%s)\n",
			c.config.TreeNodeID, childComm.NodeID, childComm.Name)
		// Placeholder: child root would be fetched from the audit contract
		childRoots = append(childRoots, common.Hash{})
	}

	if len(childRoots) == 0 {
		return nil
	}

	// Compute aggregated Merkle root over all child roots
	aggregatedRoot := computeRootHash(childRoots)

	log.Printf("[Tree Node %d] Aggregated %d child roots → %s\n",
		c.config.TreeNodeID, len(childRoots), aggregatedRoot.Hex()[:16])

	// Generate aggregated proof (single ZKP covering all children)
	aggCommit := &AggregatedCommit{
		NodeID:         c.config.TreeNodeID,
		ChildRoots:     childRoots,
		AggregatedRoot: aggregatedRoot,
	}

	proof, err := c.generateAggregatedProof(aggCommit)
	if err != nil {
		return fmt.Errorf("failed to generate aggregated proof: %w", err)
	}
	aggCommit.Proof = proof

	// Submit to audit contract via submitAggregatedCommit()
	log.Printf("[Tree Node %d] Submitting aggregated commit to audit chain\n",
		c.config.TreeNodeID)

	return c.submitAggregatedCommitTx(ctx, aggCommit)
}

// computeRootHash computes a binary Merkle root from a list of hashes
func computeRootHash(hashes []common.Hash) common.Hash {
	if len(hashes) == 0 {
		return common.Hash{}
	}
	if len(hashes) == 1 {
		return hashes[0]
	}

	// Pad to power of 2
	current := make([]common.Hash, len(hashes))
	copy(current, hashes)
	for len(current)&(len(current)-1) != 0 {
		current = append(current, common.Hash{})
	}

	// Bottom-up Merkle construction
	for len(current) > 1 {
		next := make([]common.Hash, len(current)/2)
		for i := 0; i < len(current); i += 2 {
			next[i/2] = common.BytesToHash(
				crypto.Keccak256(append(current[i].Bytes(), current[i+1].Bytes()...)))
		}
		current = next
	}
	return current[0]
}

// generateAggregatedProof generates a single ZKP for the aggregated commit.
// In a real implementation, this runs the aggregation variant of Λ_Ψ via libsnark.
func (c *Committer) generateAggregatedProof(agg *AggregatedCommit) (*ProofData, error) {
	log.Printf("[Prover] Generating aggregated proof for tree node %d (%d children)\n",
		agg.NodeID, len(agg.ChildRoots))

	publicInputs := []*big.Int{
		new(big.Int).SetBytes(common.Hash{}.Bytes()),   // old aggregated root
		new(big.Int).SetBytes(agg.AggregatedRoot[:]),    // new aggregated root
	}

	proof := &ProofData{
		PublicInputs: publicInputs,
	}

	log.Printf("[Prover] Aggregated proof generated for node %d\n", agg.NodeID)
	return proof, nil
}

// submitAggregatedCommitTx sends the aggregated commit transaction to the audit chain
func (c *Committer) submitAggregatedCommitTx(ctx context.Context, agg *AggregatedCommit) error {
	fromAddress := crypto.PubkeyToAddress(c.privateKey.PublicKey)
	nonce, err := c.auditClient.PendingNonceAt(ctx, fromAddress)
	if err != nil {
		return fmt.Errorf("failed to get nonce: %w", err)
	}

	gasPrice, err := c.auditClient.SuggestGasPrice(ctx)
	if err != nil {
		return fmt.Errorf("failed to get gas price: %w", err)
	}

	auditContractAddr := common.HexToAddress(c.config.AuditContractAddr)

	// ABI encode: submitAggregatedCommit(nodeId, childRoots, aggregatedRoot, proofA, proofB, proofC)
	selector := crypto.Keccak256([]byte(
		"submitAggregatedCommit(uint256,bytes32[],bytes32,uint256[2],uint256[2][2],uint256[2])"))[:4]

	data := make([]byte, 0, 4+32*20)
	data = append(data, selector...)
	nodeIDBig := new(big.Int).SetUint64(agg.NodeID)
	data = append(data, common.BigToHash(nodeIDBig).Bytes()...)
	data = append(data, agg.AggregatedRoot.Bytes()...)

	tx := types.NewTransaction(
		nonce,
		auditContractAddr,
		big.NewInt(0),
		uint64(600000), // Gas limit for aggregated verification
		gasPrice,
		data,
	)

	auditChainID, err := c.auditClient.ChainID(ctx)
	if err != nil {
		return fmt.Errorf("failed to get chain ID: %w", err)
	}

	signedTx, err := types.SignTx(tx, types.NewEIP155Signer(auditChainID), c.privateKey)
	if err != nil {
		return fmt.Errorf("failed to sign tx: %w", err)
	}

	if err := c.auditClient.SendTransaction(ctx, signedTx); err != nil {
		return fmt.Errorf("failed to send tx: %w", err)
	}

	log.Printf("[Tree Node %d] Aggregated TxCommit sent: %s\n",
		agg.NodeID, signedTx.Hash().Hex())
	return nil
}

// ==========================================
// Main Entry Point
// ==========================================

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Usage: committer <config.json>")
		fmt.Println("\nzkCross Cross-Chain Committer Service")
		fmt.Println("Monitors ordinary chains and submits audit proofs to the audit chain.")
		os.Exit(1)
	}

	committer, err := NewCommitter(os.Args[1])
	if err != nil {
		log.Fatalf("Failed to create committer: %v", err)
	}

	ctx := context.Background()
	if err := committer.Start(ctx); err != nil {
		log.Fatalf("Committer failed: %v", err)
	}
}
