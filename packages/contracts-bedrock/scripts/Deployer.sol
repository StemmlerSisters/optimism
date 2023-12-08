// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Executables } from "scripts/Executables.sol";
import { Chains } from "scripts/Chains.sol";
import { Predeploys } from "src/libraries/Predeploys.sol";

/// @notice store the new deployment to be saved
struct Deployment {
    string name;
    address payable addr;
}

/// @notice A `hardhat-deploy` style artifact
struct Artifact {
    string abi;
    address addr;
    string[] args;
    bytes bytecode;
    bytes deployedBytecode;
    string devdoc;
    string metadata;
    uint256 numDeployments;
    string receipt;
    bytes32 solcInputHash;
    string storageLayout;
    bytes32 transactionHash;
    string userdoc;
}

/// @notice Contains information about a storage slot. Mirrors the layout of the storage
///         slot object in Forge artifacts so that we can deserialize JSON into this struct.
struct StorageSlot {
    uint256 astId;
    string _contract;
    string label;
    uint256 offset;
    string slot;
    string _type;
}

/// @title Deployer
/// @author tynes
/// @notice A contract that can make deploying and interacting with deployments easy.
///         When a contract is deployed, call the `save` function to write its name and
///         contract address to disk. Then the `sync` function can be called to generate
///         hardhat deploy style artifacts. Forked from `forge-deploy`.
abstract contract Deployer is Script {
    /// @notice The set of deployments that have been done during execution.
    mapping(string => Deployment) internal _namedDeployments;
    /// @notice The same as `_namedDeployments` but as an array.
    Deployment[] internal _newDeployments;
    /// @notice The namespace for the deployment. Can be set with the env var DEPLOYMENT_CONTEXT.
    string internal deploymentContext;
    /// @notice Path to the deploy artifact generated by foundry
    string internal deployPath;
    /// @notice Path to the directory containing the hh deploy style artifacts
    string internal deploymentsDir;
    /// @notice The name of the deploy script that sends the transactions.
    ///         Can be modified with the env var DEPLOY_SCRIPT
    string internal deployScript;
    /// @notice The path to the temp deployments file
    string internal tempDeploymentsPath;
    /// @notice Error for when attempting to fetch a deployment and it does not exist

    error DeploymentDoesNotExist(string);
    /// @notice Error for when trying to save an invalid deployment
    error InvalidDeployment(string);
    /// @notice The storage slot that holds the address of the implementation.
    ///        bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1)

    bytes32 internal constant IMPLEMENTATION_KEY = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @notice The storage slot that holds the address of the owner.
    ///        bytes32(uint256(keccak256('eip1967.proxy.admin')) - 1)
    bytes32 internal constant OWNER_KEY = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /// @notice Create the global variables and set up the filesystem.
    ///         Forge script will create a file where the prefix is the
    ///         name of the function that runs with the suffix `-latest.json`.
    ///         By default, `run()` is called. Allow the user to use the SIG
    ///         env var to specify what function signature was called so that
    ///         the `sync()` method can be used to create hardhat deploy style
    ///         artifacts.
    function setUp() public virtual {
        string memory root = vm.projectRoot();
        deployScript = vm.envOr("DEPLOY_SCRIPT", name());

        deploymentContext = _getDeploymentContext();
        string memory sig = vm.envOr("SIG", string("run"));
        string memory deployFile = vm.envOr("DEPLOY_FILE", string.concat(sig, "-latest.json"));
        uint256 chainId = vm.envOr("CHAIN_ID", block.chainid);
        deployPath = string.concat(root, "/broadcast/", deployScript, ".s.sol/", vm.toString(chainId), "/", deployFile);

        deploymentsDir = string.concat(root, "/deployments/", deploymentContext);
        try vm.createDir(deploymentsDir, true) { } catch (bytes memory) { }

        string memory chainIdPath = string.concat(deploymentsDir, "/.chainId");
        try vm.readFile(chainIdPath) returns (string memory localChainId) {
            if (vm.envOr("STRICT_DEPLOYMENT", true)) {
                require(
                    vm.parseUint(localChainId) == chainId,
                    string.concat("Misconfigured networks: ", localChainId, " != ", vm.toString(chainId))
                );
            }
        } catch {
            vm.writeFile(chainIdPath, vm.toString(chainId));
        }
        console.log("Connected to network with chainid %s", chainId);

        tempDeploymentsPath = string.concat(deploymentsDir, "/.deploy");
        try vm.readFile(tempDeploymentsPath) returns (string memory) { }
        catch {
            vm.writeJson("{}", tempDeploymentsPath);
        }
        console.log("Storing temp deployment data in %s", tempDeploymentsPath);

        // Load addresses from a JSON file if the CONTRACT_ADDRESSES_PATH environment variable
        // is set. Great for loading addresses from `superchain-registry`.
        string memory addresses = vm.envOr("CONTRACT_ADDRESSES_PATH", string(""));
        if (bytes(addresses).length > 0) {
            console.log("Loading addresses from %s", addresses);
            _loadAddresses(addresses);
        }
    }

    /// @notice Populates the addresses to be used in a script based on a JSON file.
    ///         The format of the JSON file is the same that it output by this script
    ///         as well as the JSON files that contain addresses in the `superchain-ops`
    ///         repo. The JSON key is the name of the contract and the value is an address.
    function _loadAddresses(string memory _path) internal {
        string[] memory commands = new string[](3);
        commands[0] = "bash";
        commands[1] = "-c";
        commands[2] = string.concat("jq -cr < ", _path);
        string memory json = string(vm.ffi(commands));
        string[] memory keys = vm.parseJsonKeys(json, "");
        for (uint256 i; i < keys.length; i++) {
            string memory key = keys[i];
            address addr = stdJson.readAddress(json, string.concat("$.", key));
            save(key, addr);
        }
    }


    /// @notice Call this function to sync the deployment artifacts such that
    ///         hardhat deploy style artifacts are created.
    function sync() public {
        Deployment[] memory deployments = _getTempDeployments();
        console.log("Syncing %s deployments", deployments.length);
        console.log("Using deployment artifact %s", deployPath);

        for (uint256 i; i < deployments.length; i++) {
            address addr = deployments[i].addr;
            string memory deploymentName = deployments[i].name;

            string memory deployTx = _getDeployTransactionByContractAddress(addr);
            if (bytes(deployTx).length == 0) {
                console.log("Deploy Tx not found for %s skipping deployment artifact generation", deploymentName);
                continue;
            }
            string memory contractName = _getContractNameFromDeployTransaction(deployTx);
            console.log("Syncing deployment %s: contract %s", deploymentName, contractName);

            string[] memory args = getDeployTransactionConstructorArguments(deployTx);
            bytes memory code = _getCode(contractName);
            bytes memory deployedCode = _getDeployedCode(contractName);
            string memory receipt = _getDeployReceiptByContractAddress(addr);

            string memory artifactPath = string.concat(deploymentsDir, "/", deploymentName, ".json");

            uint256 numDeployments = 0;
            try vm.readFile(artifactPath) returns (string memory res) {
                numDeployments = stdJson.readUint(string(res), "$.numDeployments");
                vm.removeFile(artifactPath);
            } catch { }
            numDeployments++;

            Artifact memory artifact = Artifact({
                abi: getAbi(contractName),
                addr: addr,
                args: args,
                bytecode: code,
                deployedBytecode: deployedCode,
                devdoc: getDevDoc(contractName),
                metadata: getMetadata(contractName),
                numDeployments: numDeployments,
                receipt: receipt,
                solcInputHash: bytes32(0),
                storageLayout: getStorageLayout(contractName),
                transactionHash: stdJson.readBytes32(deployTx, "$.hash"),
                userdoc: getUserDoc(contractName)
            });

            string memory json = _serializeArtifact(artifact);

            vm.writeJson({ json: json, path: artifactPath });
        }

        console.log("Synced temp deploy files, deleting %s", tempDeploymentsPath);
        vm.removeFile(tempDeploymentsPath);
    }

    /// @notice Returns the name of the deployment script. Children contracts
    ///         must implement this to ensure that the deploy artifacts can be found.
    ///         This should be the same as the name of the script and is used as the file
    ///         name inside of the `broadcast` directory when looking up deployment artifacts.
    function name() public pure virtual returns (string memory);

    /// @notice Returns all of the deployments done in the current context.
    function newDeployments() external view returns (Deployment[] memory) {
        return _newDeployments;
    }

    /// @notice Returns whether or not a particular deployment exists.
    /// @param _name The name of the deployment.
    /// @return Whether the deployment exists or not.
    function has(string memory _name) public view returns (bool) {
        Deployment memory existing = _namedDeployments[_name];
        if (existing.addr != address(0)) {
            return bytes(existing.name).length > 0;
        }
        return _getExistingDeploymentAddress(_name) != address(0);
    }

    /// @notice Returns the address of a deployment. Also handles the predeploys.
    /// @param _name The name of the deployment.
    /// @return The address of the deployment. May be `address(0)` if the deployment does not
    ///         exist.
    function getAddress(string memory _name) public view returns (address payable) {
        Deployment memory existing = _namedDeployments[_name];
        if (existing.addr != address(0)) {
            if (bytes(existing.name).length == 0) {
                return payable(address(0));
            }
            return existing.addr;
        }
        address addr = _getExistingDeploymentAddress(_name);
        if (addr != address(0)) return payable(addr);

        bytes32 digest = keccak256(bytes(_name));
        if (digest == keccak256(bytes("L2CrossDomainMessenger"))) {
            return payable(Predeploys.L2_CROSS_DOMAIN_MESSENGER);
        } else if (digest == keccak256(bytes("L2ToL1MessagePasser"))) {
            return payable(Predeploys.L2_TO_L1_MESSAGE_PASSER);
        } else if (digest == keccak256(bytes("L2StandardBridge"))) {
            return payable(Predeploys.L2_STANDARD_BRIDGE);
        } else if (digest == keccak256(bytes("L2ERC721Bridge"))) {
            return payable(Predeploys.L2_ERC721_BRIDGE);
        } else if (digest == keccak256(bytes("SequencerFeeWallet"))) {
            return payable(Predeploys.SEQUENCER_FEE_WALLET);
        } else if (digest == keccak256(bytes("OptimismMintableERC20Factory"))) {
            return payable(Predeploys.OPTIMISM_MINTABLE_ERC20_FACTORY);
        } else if (digest == keccak256(bytes("OptimismMintableERC721Factory"))) {
            return payable(Predeploys.OPTIMISM_MINTABLE_ERC721_FACTORY);
        } else if (digest == keccak256(bytes("L1Block"))) {
            return payable(Predeploys.L1_BLOCK_ATTRIBUTES);
        } else if (digest == keccak256(bytes("GasPriceOracle"))) {
            return payable(Predeploys.GAS_PRICE_ORACLE);
        } else if (digest == keccak256(bytes("L1MessageSender"))) {
            return payable(Predeploys.L1_MESSAGE_SENDER);
        } else if (digest == keccak256(bytes("DeployerWhitelist"))) {
            return payable(Predeploys.DEPLOYER_WHITELIST);
        } else if (digest == keccak256(bytes("WETH9"))) {
            return payable(Predeploys.WETH9);
        } else if (digest == keccak256(bytes("LegacyERC20ETH"))) {
            return payable(Predeploys.LEGACY_ERC20_ETH);
        } else if (digest == keccak256(bytes("L1BlockNumber"))) {
            return payable(Predeploys.L1_BLOCK_NUMBER);
        } else if (digest == keccak256(bytes("LegacyMessagePasser"))) {
            return payable(Predeploys.LEGACY_MESSAGE_PASSER);
        } else if (digest == keccak256(bytes("ProxyAdmin"))) {
            return payable(Predeploys.PROXY_ADMIN);
        } else if (digest == keccak256(bytes("BaseFeeVault"))) {
            return payable(Predeploys.BASE_FEE_VAULT);
        } else if (digest == keccak256(bytes("L1FeeVault"))) {
            return payable(Predeploys.L1_FEE_VAULT);
        } else if (digest == keccak256(bytes("GovernanceToken"))) {
            return payable(Predeploys.GOVERNANCE_TOKEN);
        } else if (digest == keccak256(bytes("SchemaRegistry"))) {
            return payable(Predeploys.SCHEMA_REGISTRY);
        } else if (digest == keccak256(bytes("EAS"))) {
            return payable(Predeploys.EAS);
        }
        return payable(address(0));
    }

    /// @notice Returns the address of a deployment and reverts if the deployment
    ///         does not exist.
    /// @return The address of the deployment.
    function mustGetAddress(string memory _name) public view returns (address payable) {
        address addr = getAddress(_name);
        if (addr == address(0)) {
            revert DeploymentDoesNotExist(_name);
        }
        return payable(addr);
    }

    /// @notice Returns a deployment that is suitable to be used to interact with contracts.
    /// @param _name The name of the deployment.
    /// @return The deployment.
    function get(string memory _name) public view returns (Deployment memory) {
        Deployment memory deployment = _namedDeployments[_name];
        if (deployment.addr != address(0)) {
            return deployment;
        } else {
            return _getExistingDeployment(_name);
        }
    }

    /// @notice Writes a deployment to disk as a temp deployment so that the
    ///         hardhat deploy artifact can be generated afterwards.
    /// @param _name The name of the deployment.
    /// @param _deployed The address of the deployment.
    function save(string memory _name, address _deployed) public {
        if (bytes(_name).length == 0) {
            revert InvalidDeployment("EmptyName");
        }
        if (bytes(_namedDeployments[_name].name).length > 0) {
            revert InvalidDeployment("AlreadyExists");
        }

        Deployment memory deployment = Deployment({ name: _name, addr: payable(_deployed) });
        _namedDeployments[_name] = deployment;
        _newDeployments.push(deployment);
        _writeTemp(_name, _deployed);
    }

    /// @notice Reads the temp deployments from disk that were generated
    ///         by the deploy script.
    /// @return An array of deployments.
    function _getTempDeployments() internal returns (Deployment[] memory) {
        string memory json = vm.readFile(tempDeploymentsPath);
        string[] memory cmd = new string[](3);
        cmd[0] = Executables.bash;
        cmd[1] = "-c";
        cmd[2] = string.concat(Executables.jq, " 'keys' <<< '", json, "'");
        bytes memory res = vm.ffi(cmd);
        string[] memory names = stdJson.readStringArray(string(res), "");

        Deployment[] memory deployments = new Deployment[](names.length);
        for (uint256 i; i < names.length; i++) {
            string memory contractName = names[i];
            address addr = stdJson.readAddress(json, string.concat("$.", contractName));
            deployments[i] = Deployment({ name: contractName, addr: payable(addr) });
        }
        return deployments;
    }

    /// @notice Returns the json of the deployment transaction given a contract address.
    function _getDeployTransactionByContractAddress(address _addr) internal returns (string memory) {
        string[] memory cmd = new string[](3);
        cmd[0] = Executables.bash;
        cmd[1] = "-c";
        cmd[2] = string.concat(
            Executables.jq,
            " -r '.transactions[] | select(.contractAddress == ",
            '"',
            vm.toString(_addr),
            '"',
            ') | select(.transactionType == "CREATE"',
            ' or .transactionType == "CREATE2"',
            ")' < ",
            deployPath
        );
        bytes memory res = vm.ffi(cmd);
        return string(res);
    }

    /// @notice Returns the contract name from a deploy transaction.
    function _getContractNameFromDeployTransaction(string memory _deployTx) internal pure returns (string memory) {
        return stdJson.readString(_deployTx, ".contractName");
    }

    /// @notice Wrapper for vm.getCode that handles semver in the name.
    function _getCode(string memory _name) internal returns (bytes memory) {
        string memory fqn = _getFullyQualifiedName(_name);
        bytes memory code = vm.getCode(fqn);
        return code;
    }

    /// @notice Wrapper for vm.getDeployedCode that handles semver in the name.
    function _getDeployedCode(string memory _name) internal returns (bytes memory) {
        string memory fqn = _getFullyQualifiedName(_name);
        bytes memory code = vm.getDeployedCode(fqn);
        return code;
    }

    /// @notice Removes the semantic versioning from a contract name. The semver will exist if the contract is compiled
    /// more than once with different versions of the compiler.
    function _stripSemver(string memory _name) internal returns (string memory) {
        string[] memory cmd = new string[](3);
        cmd[0] = Executables.bash;
        cmd[1] = "-c";
        cmd[2] = string.concat(
            Executables.echo, " ", _name, " | ", Executables.sed, " -E 's/[.][0-9]+\\.[0-9]+\\.[0-9]+//g'"
        );
        bytes memory res = vm.ffi(cmd);
        return string(res);
    }

    /// @notice Returns the constructor arguent of a deployment transaction given a transaction json.
    function getDeployTransactionConstructorArguments(string memory _transaction) internal returns (string[] memory) {
        string[] memory cmd = new string[](3);
        cmd[0] = Executables.bash;
        cmd[1] = "-c";
        cmd[2] = string.concat(Executables.jq, " -r '.arguments' <<< '", _transaction, "'");
        bytes memory res = vm.ffi(cmd);

        string[] memory args = new string[](0);
        if (keccak256(bytes("null")) != keccak256(res)) {
            args = stdJson.readStringArray(string(res), "");
        }
        return args;
    }

    /// @notice Builds the fully qualified name of a contract. Assumes that the
    ///         file name is the same as the contract name but strips semver for the file name.
    function _getFullyQualifiedName(string memory _name) internal returns (string memory) {
        string memory sanitized = _stripSemver(_name);
        return string.concat(sanitized, ".sol:", _name);
    }

    function _getForgeArtifactDirectory(string memory _name) internal returns (string memory dir_) {
        string[] memory cmd = new string[](3);
        cmd[0] = Executables.bash;
        cmd[1] = "-c";
        cmd[2] = string.concat(Executables.forge, " config --json | ", Executables.jq, " -r .out");
        bytes memory res = vm.ffi(cmd);
        string memory contractName = _stripSemver(_name);
        dir_ = string.concat(vm.projectRoot(), "/", string(res), "/", contractName, ".sol");
    }

    /// @notice Returns the filesystem path to the artifact path. If the contract was compiled
    ///         with multiple solidity versions then return the first one based on the result of `ls`.
    function _getForgeArtifactPath(string memory _name) internal returns (string memory) {
        string memory directory = _getForgeArtifactDirectory(_name);
        string memory path = string.concat(directory, "/", _name, ".json");
        if (vm.exists(path)) return path;

        string[] memory cmd = new string[](3);
        cmd[0] = Executables.bash;
        cmd[1] = "-c";
        cmd[2] = string.concat(
            Executables.ls,
            " -1 --color=never ",
            directory,
            " | ",
            Executables.jq,
            " -R -s -c 'split(\"\n\") | map(select(length > 0))'"
        );
        bytes memory res = vm.ffi(cmd);
        string[] memory files = stdJson.readStringArray(string(res), "");
        return string.concat(directory, "/", files[0]);
    }

    /// @notice Returns the forge artifact given a contract name.
    function _getForgeArtifact(string memory _name) internal returns (string memory) {
        string memory forgeArtifactPath = _getForgeArtifactPath(_name);
        return vm.readFile(forgeArtifactPath);
    }

    /// @notice Returns the receipt of a deployment transaction.
    function _getDeployReceiptByContractAddress(address _addr) internal returns (string memory receipt_) {
        string[] memory cmd = new string[](3);
        cmd[0] = Executables.bash;
        cmd[1] = "-c";
        cmd[2] = string.concat(
            Executables.jq,
            " -r '.receipts[] | select(.contractAddress == ",
            '"',
            vm.toString(_addr),
            '"',
            ")' < ",
            deployPath
        );
        bytes memory res = vm.ffi(cmd);
        string memory receipt = string(res);
        receipt_ = receipt;
    }

    /// @notice Returns the devdoc for a deployed contract.
    function getDevDoc(string memory _name) internal returns (string memory doc_) {
        string[] memory cmd = new string[](3);
        cmd[0] = Executables.bash;
        cmd[1] = "-c";
        cmd[2] = string.concat(Executables.jq, " -r '.devdoc' < ", _getForgeArtifactPath(_name));
        bytes memory res = vm.ffi(cmd);
        doc_ = string(res);
    }

    /// @notice Returns the storage layout for a deployed contract.
    function getStorageLayout(string memory _name) internal returns (string memory layout_) {
        string[] memory cmd = new string[](3);
        cmd[0] = Executables.bash;
        cmd[1] = "-c";
        cmd[2] = string.concat(Executables.jq, " -r '.storageLayout' < ", _getForgeArtifactPath(_name));
        bytes memory res = vm.ffi(cmd);
        layout_ = string(res);
    }

    /// @notice Returns the abi for a deployed contract.
    function getAbi(string memory _name) public returns (string memory abi_) {
        string[] memory cmd = new string[](3);
        cmd[0] = Executables.bash;
        cmd[1] = "-c";
        cmd[2] = string.concat(Executables.jq, " -r '.abi' < ", _getForgeArtifactPath(_name));
        bytes memory res = vm.ffi(cmd);
        abi_ = string(res);
    }

    /// @notice
    function getMethodIdentifiers(string memory _name) public returns (string[] memory ids_) {
        string[] memory cmd = new string[](3);
        cmd[0] = Executables.bash;
        cmd[1] = "-c";
        cmd[2] = string.concat(Executables.jq, " '.methodIdentifiers | keys' < ", _getForgeArtifactPath(_name));
        bytes memory res = vm.ffi(cmd);
        ids_ = stdJson.readStringArray(string(res), "");
    }

    /// @notice Returns the userdoc for a deployed contract.
    function getUserDoc(string memory _name) internal returns (string memory doc_) {
        string[] memory cmd = new string[](3);
        cmd[0] = Executables.bash;
        cmd[1] = "-c";
        cmd[2] = string.concat(Executables.jq, " -r '.userdoc' < ", _getForgeArtifactPath(_name));
        bytes memory res = vm.ffi(cmd);
        doc_ = string(res);
    }

    /// @notice
    function getMetadata(string memory _name) internal returns (string memory metadata_) {
        string[] memory cmd = new string[](3);
        cmd[0] = Executables.bash;
        cmd[1] = "-c";
        cmd[2] = string.concat(Executables.jq, " '.metadata | tostring' < ", _getForgeArtifactPath(_name));
        bytes memory res = vm.ffi(cmd);
        metadata_ = string(res);
    }

    /// @dev Pulls the `_initialized` storage slot information from the Forge artifacts for a given contract.
    function getInitializedSlot(string memory _contractName) internal returns (StorageSlot memory slot_) {
        string memory storageLayout = getStorageLayout(_contractName);

        string[] memory command = new string[](3);
        command[0] = Executables.bash;
        command[1] = "-c";
        command[2] = string.concat(
            Executables.echo,
            " '",
            storageLayout,
            "'",
            " | ",
            Executables.jq,
            " '.storage[] | select(.label == \"_initialized\" and .type == \"t_uint8\")'"
        );
        bytes memory rawSlot = vm.parseJson(string(vm.ffi(command)));
        slot_ = abi.decode(rawSlot, (StorageSlot));
    }

    /// @dev Returns the value of the internal `_initialized` storage slot for a given contract.
    function loadInitializedSlot(string memory _contractName, bool _isProxy) public returns (uint8 initialized_) {
        StorageSlot memory slot = getInitializedSlot(_contractName);
        if (_isProxy) {
            _contractName = string.concat(_contractName, "Proxy");
        }
        bytes32 slotVal = vm.load(mustGetAddress(_contractName), bytes32(vm.parseUint(slot.slot)));
        initialized_ = uint8((uint256(slotVal) >> (slot.offset * 8)) & 0xFF);
    }

    /// @notice Adds a deployment to the temp deployments file
    function _writeTemp(string memory _name, address _deployed) internal {
        vm.writeJson({ json: stdJson.serialize("", _name, _deployed), path: tempDeploymentsPath });
    }

    /// @notice Turns an Artifact into a json serialized string
    /// @param _artifact The artifact to serialize
    /// @return The json serialized string
    function _serializeArtifact(Artifact memory _artifact) internal returns (string memory) {
        string memory json = "";
        json = stdJson.serialize("", "address", _artifact.addr);
        json = stdJson.serialize("", "abi", _artifact.abi);
        json = stdJson.serialize("", "args", _artifact.args);
        json = stdJson.serialize("", "bytecode", _artifact.bytecode);
        json = stdJson.serialize("", "deployedBytecode", _artifact.deployedBytecode);
        json = stdJson.serialize("", "devdoc", _artifact.devdoc);
        json = stdJson.serialize("", "metadata", _artifact.metadata);
        json = stdJson.serialize("", "numDeployments", _artifact.numDeployments);
        json = stdJson.serialize("", "receipt", _artifact.receipt);
        json = stdJson.serialize("", "solcInputHash", _artifact.solcInputHash);
        json = stdJson.serialize("", "storageLayout", _artifact.storageLayout);
        json = stdJson.serialize("", "transactionHash", _artifact.transactionHash);
        json = stdJson.serialize("", "userdoc", _artifact.userdoc);
        return json;
    }

    /// @notice The context of the deployment is used to namespace the artifacts.
    ///         An unknown context will use the chainid as the context name.
    function _getDeploymentContext() private returns (string memory) {
        string memory context = vm.envOr("DEPLOYMENT_CONTEXT", string(""));
        if (bytes(context).length > 0) {
            return context;
        }

        uint256 chainid = vm.envOr("CHAIN_ID", block.chainid);
        if (chainid == Chains.Mainnet) {
            return "mainnet";
        } else if (chainid == Chains.Goerli) {
            return "goerli";
        } else if (chainid == Chains.OPGoerli) {
            return "optimism-goerli";
        } else if (chainid == Chains.OPMainnet) {
            return "optimism-mainnet";
        } else if (chainid == Chains.LocalDevnet || chainid == Chains.GethDevnet) {
            return "devnetL1";
        } else if (chainid == Chains.Hardhat) {
            return "hardhat";
        } else if (chainid == Chains.Sepolia) {
            return "sepolia";
        } else if (chainid == Chains.OPSepolia) {
            return "optimism-sepolia";
        } else {
            return vm.toString(chainid);
        }
    }

    /// @notice Reads the artifact from the filesystem by name and returns the address.
    /// @param _name The name of the artifact to read.
    /// @return The address of the artifact.
    function _getExistingDeploymentAddress(string memory _name) internal view returns (address payable) {
        return _getExistingDeployment(_name).addr;
    }

    /// @notice Reads the artifact from the filesystem by name and returns the Deployment.
    /// @param _name The name of the artifact to read.
    /// @return The deployment corresponding to the name.
    function _getExistingDeployment(string memory _name) internal view returns (Deployment memory) {
        string memory path = string.concat(deploymentsDir, "/", _name, ".json");
        try vm.readFile(path) returns (string memory json) {
            bytes memory addr = stdJson.parseRaw(json, "$.address");
            return Deployment({ addr: abi.decode(addr, (address)), name: _name });
        } catch {
            return Deployment({ addr: payable(address(0)), name: "" });
        }
    }
}
