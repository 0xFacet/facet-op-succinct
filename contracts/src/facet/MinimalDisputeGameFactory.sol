// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Libraries
import { LibClone } from "../../lib/solady/src/utils/LibClone.sol";
import { GameType, Claim, GameId, Timestamp, Hash, LibGameId } from "../../lib/optimism/packages/contracts-bedrock/src/dispute/lib/Types.sol";
import { NoImplementation, IncorrectBondAmount, GameAlreadyExists } from "../../lib/optimism/packages/contracts-bedrock/src/dispute/lib/Errors.sol";

// Interfaces
import { ISemver } from "../../lib/optimism/packages/contracts-bedrock/interfaces/universal/ISemver.sol";
import { IDisputeGame } from "../../lib/optimism/packages/contracts-bedrock/interfaces/dispute/IDisputeGame.sol";

// Contracts
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MinimalDisputeGameFactory
/// @notice A minimal factory for creating IDisputeGame contracts without upgradeability.
///         All created dispute games are stored in both a mapping and an append-only array.
contract MinimalDisputeGameFactory is ISemver, Ownable {
    using LibClone for address;
    using LibGameId for GameId;

    /// @notice Emitted when a new dispute game is created
    event DisputeGameCreated(address indexed disputeProxy, GameType indexed gameType, Claim indexed rootClaim);

    /// @notice Emitted when a new game implementation is set
    event ImplementationSet(address indexed impl, GameType indexed gameType);

    /// @notice Emitted when a game type's initialization bond is updated
    event InitBondUpdated(GameType indexed gameType, uint256 indexed newBond);

    /// @notice Information about a dispute game found in a search
    struct GameSearchResult {
        uint256 index;
        GameId metadata;
        Timestamp timestamp;
        Claim rootClaim;
        bytes extraData;
    }

    /// @notice Semantic version
    string public constant version = "0.1.0";

    /// @notice Mapping of game type to implementation contract
    mapping(GameType => IDisputeGame) public gameImpls;

    /// @notice Mapping of game type to initialization bond (in wei)
    mapping(GameType => uint256) public initBonds;

    /// @notice Mapping of game UUID to proxy address
    mapping(Hash => GameId) internal _disputeGames;

    /// @notice Array of created game proxies
    GameId[] internal _disputeGameList;

    /// @notice Creates a new DisputeGame proxy contract
    /// @param _gameType The type of the DisputeGame to create
    /// @param _rootClaim The root claim of the DisputeGame
    /// @param _extraData Any extra data to be passed to the DisputeGame
    /// @return proxy_ The address of the created DisputeGame proxy
    function create(
        GameType _gameType,
        Claim _rootClaim,
        bytes calldata _extraData
    ) external payable returns (IDisputeGame proxy_) {
        // Get the implementation for the given game type
        IDisputeGame impl = gameImpls[_gameType];
        
        if (address(impl) == address(0)) revert NoImplementation(_gameType);

        // Check that the bond is correct
        if (msg.value != initBonds[_gameType]) revert IncorrectBondAmount();
        
        bytes32 parentHash = blockhash(block.number - 1);
        
        proxy_ = IDisputeGame(address(impl).clone(abi.encodePacked(msg.sender, _rootClaim, parentHash, _extraData)));
        proxy_.initialize{ value: msg.value }();

        // Compute the unique identifier for the dispute game.
        Hash uuid = getGameUUID(_gameType, _rootClaim, _extraData);

        // If a dispute game with the same UUID already exists, revert.
        if (GameId.unwrap(_disputeGames[uuid]) != bytes32(0)) revert GameAlreadyExists(uuid);

        // Pack the game ID.
        GameId id = LibGameId.pack(_gameType, Timestamp.wrap(uint64(block.timestamp)), address(proxy_));

        // Store the dispute game id in the mapping & emit the `DisputeGameCreated` event.
        _disputeGames[uuid] = id;
        _disputeGameList.push(id);
        emit DisputeGameCreated(address(proxy_), _gameType, _rootClaim);
    }

    /// @notice Sets the implementation for a game type
    /// @param _gameType The game type to set the implementation for
    /// @param _impl The implementation contract for the game type
    function setImplementation(GameType _gameType, IDisputeGame _impl) external onlyOwner {
        gameImpls[_gameType] = _impl;
        emit ImplementationSet(address(_impl), _gameType);
    }

    /// @notice Sets the initialization bond for a game type
    /// @param _gameType The game type to set the bond for
    /// @param _initBond The bond amount in wei
    function setInitBond(GameType _gameType, uint256 _initBond) external onlyOwner {
        initBonds[_gameType] = _initBond;
        emit InitBondUpdated(_gameType, _initBond);
    }

    /// @notice Returns the total number of games created
    function gameCount() external view returns (uint256 gameCount_) {
        return _disputeGameList.length;
    }

    // /// @notice Returns the game data for a given UUID
    // /// @param _uuid The UUID of the dispute game
    // /// @return gameType_ The type of the dispute game
    // /// @return timestamp_ The timestamp of the dispute game
    // /// @return proxy_ The proxy address of the dispute game
    // function games(
    //     Hash _uuid
    // ) external view returns (GameType gameType_, Timestamp timestamp_, IDisputeGame proxy_) {
    //     GameId id = _disputeGames[_uuid];
    //     address proxyAddr;
    //     (gameType_, timestamp_, proxyAddr) = id.unpack();
    //     proxy_ = IDisputeGame(proxyAddr);
    // }
    
    /// @notice `games` queries an internal mapping that maps the hash of
    ///         `gameType ++ rootClaim ++ extraData` to the deployed `DisputeGame` clone.
    /// @dev `++` equates to concatenation.
    /// @param _gameType The type of the DisputeGame - used to decide the proxy implementation
    /// @param _rootClaim The root claim of the DisputeGame.
    /// @param _extraData Any extra data that should be provided to the created dispute game.
    /// @return proxy_ The clone of the `DisputeGame` created with the given parameters.
    ///         Returns `address(0)` if nonexistent.
    /// @return timestamp_ The timestamp of the creation of the dispute game.
    function games(
        GameType _gameType,
        Claim _rootClaim,
        bytes calldata _extraData
    )
        external
        view
        returns (IDisputeGame proxy_, Timestamp timestamp_)
    {
        Hash uuid = getGameUUID(_gameType, _rootClaim, _extraData);
        (, Timestamp timestamp, address proxy) = _disputeGames[uuid].unpack();
        (proxy_, timestamp_) = (IDisputeGame(proxy), timestamp);
    }

    /// @notice Returns the game data at a given index
    /// @param _index The index in the dispute game list
    /// @return gameType_ The type of the dispute game  
    /// @return timestamp_ The timestamp of the dispute game
    /// @return proxy_ The proxy address of the dispute game
    function gameAtIndex(
        uint256 _index
    ) external view returns (GameType gameType_, Timestamp timestamp_, IDisputeGame proxy_) {
        GameId id = _disputeGameList[_index];
        address proxyAddr;
        (gameType_, timestamp_, proxyAddr) = id.unpack();
        proxy_ = IDisputeGame(proxyAddr);
    }

    /// @notice Finds games matching specific criteria
    /// @param _gameType The game type to search for
    /// @param _start The index to start searching from
    /// @param _n The maximum number of games to return
    /// @return games_ An array of found games
    function findLatestGames(
        GameType _gameType,
        uint256 _start,
        uint256 _n
    ) external view returns (GameSearchResult[] memory games_) {
        uint256 gamesFound = 0;
        uint256 listLen = _disputeGameList.length;
        
        if (_start >= listLen) return games_;

        // Allocate memory for the max possible results
        games_ = new GameSearchResult[](_n);

        // Search backwards from start position
        for (uint256 i = _start; i < listLen && gamesFound < _n; i++) {
            GameId id = _disputeGameList[listLen - i - 1];
            (GameType gameType, Timestamp timestamp, address addr) = id.unpack();
            IDisputeGame proxy = IDisputeGame(addr);
            
            if (gameType.raw() == _gameType.raw()) {
                games_[gamesFound] = GameSearchResult({
                    index: listLen - i - 1,
                    metadata: id,
                    timestamp: timestamp,
                    rootClaim: proxy.rootClaim(),
                    extraData: proxy.extraData()
                });
                gamesFound++;
            }
        }

        // Resize array to actual number of games found
        assembly {
            mstore(games_, gamesFound)
        }
    }
    
    /// @notice Returns a unique identifier for the given dispute game parameters.
    /// @dev Hashes the concatenation of `gameType . rootClaim . extraData`
    ///      without expanding memory.
    /// @param _gameType The type of the DisputeGame.
    /// @param _rootClaim The root claim of the DisputeGame.
    /// @param _extraData Any extra data that should be provided to the created dispute game.
    /// @return uuid_ The unique identifier for the given dispute game parameters.
    function getGameUUID(
        GameType _gameType,
        Claim _rootClaim,
        bytes calldata _extraData
    )
        public
        pure
        returns (Hash uuid_)
    {
        uuid_ = Hash.wrap(keccak256(abi.encode(_gameType, _rootClaim, _extraData)));
    }

}
