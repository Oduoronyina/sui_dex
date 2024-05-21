/**
 * @title DEX Contract
 * @dev This contract implements a decentralized exchange (DEX) where users can trade ETH and USDC tokens.
 *      It also includes functionality to reward users with a custom DEX token every 2 swaps.
 *      The contract manages the creation of the DEX coin, the storage of user swap and minting data,
 *      and the execution of market and limit orders.
 */
module dex::dex {
  use std::option;
  use std::type_name::{get, TypeName};

  use sui::transfer;
  use sui::sui::SUI;
  use sui::clock::{Clock};
  use sui::balance::{Self, Supply};
  use sui::object::{Self, UID};
  use sui::table::{Self, Table};
  use sui::dynamic_field as df;
  use sui::tx_context::{Self, TxContext};
  use sui::coin::{Self, TreasuryCap, Coin};

  use deepbook::clob_v2::{Self as clob, Pool};
  use deepbook::custodian_v2::AccountCap;

  use dex::eth::ETH;
  use dex::usdc::USDC;

  const CLIENT_ID: u64 = 122227;
  const MAX_U64: u64 = 18446744073709551615;
  // Restrictions on limit orders.
  const NO_RESTRICTION: u8 = 0;
  const FLOAT_SCALING: u64 = 1_000_000_000; // 1e9

  const EAlreadyMintedThisEpoch: u64 = 0;

  // One time witness to create the DEX coin
  struct DEX has drop {}

  struct Data<phantom CoinType> has store {
    cap: TreasuryCap<CoinType>,
    /*
    * This table will store user address => last epoch minted
    * this is to make sure that users can only mint tokens once per epoch
    */
    faucet_lock: Table<address, u64>
  }

  // This is an object because it has the key ability and a UID
  struct Storage has key {
    id: UID,
    dex_supply: Supply<DEX>,
    swaps: Table<address, u64>,
    account_cap: AccountCap,
    client_id: u64
  }

  #[allow(unused_function)]
  // This function only runs at deployment
  fun init(witness: DEX, ctx: &mut TxContext) { 

  let (treasury_cap, metadata) = coin::create_currency<DEX>(
            witness, 
            9, 
            b"DEX",
            b"DEX Coin", 
            b"Coin of SUI DEX", 
            option::none(), 
            ctx
        );
    
    // Share the metadata with sui network and make it immutable
    transfer::public_freeze_object(metadata);    


    // We share the Storage object with the Sui Network so everyone can pass to functions as a reference
    // We transform the Treasury Cap into a Supply so this module can mint the DEX token
    transfer::share_object(Storage { 
      id: object::new(ctx), 
      dex_supply: coin::treasury_into_supply(treasury_cap), 
      swaps: table::new(ctx),
      // We will store the deployer account_cap here to be able to refill the pool
      account_cap: clob::create_account(ctx),
      client_id: CLIENT_ID
    });
  }

  // * VIEW FUNCTIONS

  // Returns the last epoch the user minted a coin and the user's swap count
  public fun user_data<CoinType>(self: &Storage, user: address): (u64, u64) {
    // Load the Coin Data from storage
    let data = df::borrow<TypeName, Data<CoinType>>(&self.id, get<CoinType>());

    // Check if the user has ever used the faucet
    let last_mint_epoch = if (table::contains(&data.faucet_lock, user)) {
      *table::borrow(&data.faucet_lock, user)
    } else {
      0
    };

    // Check if the user has ever swapped
    let swap_count = if (table::contains(&self.swaps, user)) {
      *table::borrow(&self.swaps, user)
    } else {
      0
    };

    (last_mint_epoch, swap_count)
  }

  // * MUT FUNCTIONS

  public fun entry_place_market_order(
    self: &mut Storage,
    pool: &mut Pool<ETH, USDC>,
    account_cap: &AccountCap,
    quantity: u64,
    is_bid: bool,
    base_coin: Coin<ETH>,
    quote_coin: Coin<USDC>,
    c: &Clock,
    ctx: &mut TxContext,   
  ) {
    // Call place market order
    let (eth, usdc, coin_dex) = place_market_order(self, pool, account_cap, quantity, is_bid, base_coin, quote_coin, c, ctx);
    // Save sender in memory
    let sender = tx_context::sender(ctx);

    // Transfer coin if it has value, otherwise destroy it
    transfer_coin(eth, sender);
    transfer_coin(usdc, sender);
    transfer_coin(coin_dex, sender);
  }

  /*
  * @param self The shared object of this contract
  * @param pool The DeepBook pool we are trading with
  * @param account_cap All users on deep book need an AccountCap to place orders
  * @param quantity The number of Base tokens we wish to buy or sell (In this case ETH)
  * @param is_bid Are we buying or selling ETH
  * @param base_coin ETH
  * @param quote_coin USDC
  * @param c The Clock shared object
  */
  public fun place_market_order(
    self: &mut Storage,
    pool: &mut Pool<ETH, USDC>,
    account_cap: &AccountCap,
    quantity: u64,
    is_bid: bool,
    base_coin: Coin<ETH>,
    quote_coin: Coin<USDC>,
    c: &Clock,
    ctx: &mut TxContext,    
  ): (Coin<ETH>, Coin<USDC>, Coin<DEX>) {
  let sender = tx_context::sender(ctx);  

  let client_order_id = 0;
  let dex_coin = coin::zero(ctx);

  // Update the user's swap count and mint DEX token if applicable
  if (table::contains(&self.swaps, sender)) {
    let total_swaps = table::borrow_mut(&mut self.swaps, sender);
    *total_swaps += 1;
    client_order_id = *total_swaps;

    if (*total_swaps % 2 == 0) {
      coin::join(&mut dex_coin, coin::from_balance(balance::increase_supply(&mut self.dex_supply, FLOAT_SCALING), ctx));
    }
  } else {
    table::add(&mut self.swaps, sender, 1);
  }
  
  // Place the market order
  let (eth_coin, usdc_coin) = clob::place_market_order<ETH, USDC>(
    pool, 
    account_cap, 
    client_order_id, 
    quantity,
    is_bid,
    base_coin,
    quote_coin,
    c,
    ctx
  );

  (eth_coin, usdc_coin, dex_coin)
  }
  
  // It costs 100 Sui to create a Pool in Deep Book
  public fun create_pool(fee: Coin<SUI>, ctx: &mut TxContext) {
    // Create ETH USDC pool in DeepBook
    // This pool will be shared with the Sui Network
    // Tick size is 1 USDC - 1e9 
    // No minimum lot size
    clob::create_pool<ETH, USDC>(1 * FLOAT_SCALING, 1, fee, ctx);
  }

  // Initialize the pool with limit orders for trading
  public fun initialize_pool(
    self: &mut Storage,
    pool: &mut Pool<ETH, USDC>,
    c: &Clock,
    ctx: &mut TxContext
  ) {
    /*
    * Deposit funds in DeepBook
    * Place Limit Sell Orders
    * Place Buy Sell Orders
    * To allow other users to buy/sell tokens
    */
    initialize_orders(self, pool, c, ctx);
  }

  // Initialize limit buy and sell orders
  fun initialize_orders(
    self: &mut Storage,
    pool: &mut Pool<ETH, USDC>,
    c: &Clock,
    ctx: &mut TxContext
  ) {
    // Get ETH data from storage using dynamic field
    let eth_data = df::borrow_mut<TypeName, Data<ETH>>(&mut self.id, get<ETH>());

    // Deposit 60,000 ETH on the pool
    clob::deposit_base<ETH, USDC>(pool, coin::mint(&mut eth_data.cap, 60000000000000, ctx), &self.account_cap);

    // Limit SELL Order: Sell 6000 ETH at 120 USDC
    clob::place_limit_order(
      pool,
      self.client_id,
      120 * FLOAT_SCALING,
      60000000000000,
      NO_RESTRICTION,
      false,
      MAX_U64, // no expire timestamp
      NO_RESTRICTION,
      c,
      &self.account_cap,
      ctx
    );

    self.client_id += 1;

    // Get the USDC data from the storage
    let usdc_data = df::borrow_mut<TypeName, Data<USDC>>(&mut self.id, get<USDC>());

    // Deposit 6,000,000 USDC in the pool
    clob::deposit_quote<ETH, USDC>(pool, coin::mint(&mut usdc_data.cap, 6000000000000000, ctx), &self.account_cap);

    // Limit BUY Order: Buy 6000 ETH at 100 USDC or higher
    clob::place_limit_order(
      pool,
      self.client_id,
      100 * FLOAT_SCALING,
      60000000000000,
      NO_RESTRICTION,
      true,
      MAX_U64, // no expire timestamp
      NO_RESTRICTION,
      c,
      &self.account_cap,
      ctx
    );

    self.client_id += 1;
  }

  // Since the Caps are only created at deployment, this function can only be called once
  public fun initialize_state(
    self: &mut Storage,
    eth_cap: TreasuryCap<ETH>,
    usdc_cap: TreasuryCap<USDC>,
    ctx: &mut TxContext
  ) {
    // Save the caps inside the Storage object with dynamic object fields
    df::add(&mut self.id, get<ETH>(), Data { cap: eth_cap, faucet_lock: table::new(ctx) });
    df::add(&mut self.id, get<USDC>(), Data { cap: usdc_cap, faucet_lock: table::new(ctx) });
  }

  //@dev Only call this function with ETH and USDC types
  // It mints 100 USDC every epoch or 1 ETH every epoch
  public fun mint_coin<CoinType>(self: &mut Storage, ctx: &mut TxContext): Coin<CoinType> {
    let sender = tx_context::sender(ctx);
    let current_epoch = tx_context::epoch(ctx);
    let type = get<CoinType>();
    let data = df::borrow_mut<TypeName, Data<CoinType>>(&mut self.id, type);

    // Check if the sender has minted in the current epoch
    if (table::contains(&data.faucet_lock, sender)) {
      let last_mint_epoch = table::borrow(&data.faucet_lock, sender);
      if (current_epoch <= *last_mint_epoch) {
        // The user has already minted in the current epoch
        return coin::zero(ctx);
      }
    }

    // Update the last mint epoch for the sender
    table::add_or_update(&mut data.faucet_lock, sender, current_epoch);

    // Mint coin: 100 USDC or 1 ETH
    coin::mint(&mut data.cap, if (type == get<USDC>()) 100 * FLOAT_SCALING else 1 * FLOAT_SCALING, ctx)
  }

  fun transfer_coin<CoinType>(c: Coin<CoinType>, sender: address) {
    // Check if the coin has any value before transferring or destroying
    let value = coin::value(&c);
    if (value == 0) {
      coin::destroy_zero(c);
    } else {
      transfer::public_transfer(c, sender);
    }
  }

  #[test_only]
  public fun init_for_testing(ctx: &mut TxContext) {
    init(DEX {}, ctx);
  }
}
