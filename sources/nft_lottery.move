/* 
    This quest features a NFT lottery where users can create their own lotteries with an NFT as the 
    prize. Each Lottery is a shared object in which the creator receives a `WithdrawalCapability` 
    which can be used to withdraw the ticket sales once the lottery has been run and a winner has 
    been announced.

    Creating a lottery:
        A lottery is created using the `create` entry function which requires the transfer of an NFT 
        and other parameters for the lottery, such as length in time, prize per ticket and the upper 
        range of ticket numbers. A `Lottery` shared object is created which defines the parameters 
        of the lottery, holds the NFT prize and collects ticket payments. The `WithdrawalCapability` 
        allows the owner of this object to withdraw from the corresponding `Lottery` once it has 
        successfully run.
    
    Buying a ticket:
        Once a lottery is created, any user can purchase a ticket and will receive a `LotteryTicket` 
        as proof of this purchase. The user can select any number that they wish as long as the 
        number hasn't already been sold and is within the range specified for the lottery. Payment 
        is in SUI and must be greater or equal than the price per ticket for the lottery.

    Running the lottery:
        Anyone can run the lottery if and only if the end date has passed. Tickets for the lottery 
        aren't available for purchase after the lottery has been run.  A pseudorandom number is 
        generated on chain and if there is a match to one of the bought tickets the lottery is 
        complete and the winner may collect their prize via `claim_prize`.  If no match is found 
        then the `run` entry function can be called until a winner is found. 

        A lottery cannot be run if it has already been run, if the end date has not passed, or if 
        the minimum number of participants has not been reached.

    Cancellation period:
        A lottery may be cancelled by anyone if the lottery has not been run and it is at least 7 
        days past the end date. If the lottery has been cancelled, the creator can receive their NFT 
        back and players can refund their purchased tickets.
    
    Burning tickets:
        At any point, the owner of a ticket can burn their ticket. 
    
*/
module overmind::nft_lottery {
    //==============================================================================================
    // Dependencies - DO NOT MODIFY
    //==============================================================================================
    use sui::event;
    use sui::sui::SUI;
    use sui::transfer::{Self};
    use sui::object::{Self, UID, ID};
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::tx_context::TxContext;
    use std::option::{Self, Option};
    use sui::vec_set::{Self, VecSet};
    use sui::balance::{Self, Balance};
    
    //==============================================================================================
    // Constants - Add your constants here (if any)
    //==============================================================================================

    //==============================================================================================
    // Error codes - DO NOT MODIFY
    //==============================================================================================
    /// No LotteryCapability
    const ENoWithdrawalCapability: u64 = 1;
    /// Invalid range
    const EInvalidRange: u64 = 2;
    /// In the past
    const EStartOrEndTimeInThePast: u64 = 3;
    /// Lottery has already run
    const ELotteryHasAlreadyRun: u64 = 4;
    /// Insufficient funds
    const EInsufficientFunds: u64 = 5;
    /// Ticket Already Gone
    const ETicketAlreadyGone: u64 = 6;
    /// No prize available
    const ENoPrizeAvailable: u64 = 7;
    /// Not winning number
    const ENotWinningNumber: u64 = 8;
    /// Ticket Not Available
    const ETicketNotAvailable: u64 = 9;
    /// Not withing conditions to abort
    const ENotCancelled: u64 = 10;
    /// Invalid number of participants
    const EInvalidNumberOfParticipants: u64 = 11;
    /// Ticket not found
    const ETicketNotFound: u64 = 12;
    /// Lottery cancelled
    const ELotteryCancelled: u64 = 13;
    /// Lottery has no winning number
    const ELotteryHasNoWinningNumber: u64 = 14;
    /// Invalid lottery
    const EInvalidLottery: u64 = 15;

    //==============================================================================================
    // Module Structs - DO NOT MODIFY
    //==============================================================================================

    /*
        The `Lottery` represents a lottery to be run.  A `Lottery` is a Sui shared object which can be created
        by anyone and the prize is an NFT which is moved to the Lottery shared object.  
        The creator would receive a `LotteryWithdrawal` object that would give them the capability to
        make a withdrawal from the Lottery when it has completed.
        @param id - The object id of the Lottery object.
        @param nft - The NFT as a prize for the lottery, this will `none` when the prize has been won.
        @param participants - The minimum required number of participants for the Lottery. The 
        minimum is 1.
        @param price - The price per ticket of the lottery
        @param balance - The balance available from the sale of tickets
        @param range - The upper limit for the lottery numbers. The minimum range is 1000.
        @param winning_number - The winning number for the lottery. This will be `none` until the lottery has been run.
        @param start_time - The time in ms since Epoch for when the lottery would accept purchase of tickets
        @param end_time - The time in ms since Epoch when the lottery will end
        @param tickets - A set of ticket numbers that have been bought
        @param cancelled - If the lottery has been cancelled
    */
    struct Lottery<T: key + store> has key {
        id: UID,
        nft: Option<T>,
        participants: u64, 
        price: u64,
        balance: Balance<SUI>,
        range: u64,
        winning_number: Option<u64>,
        start_time: u64,
        end_time: u64,
        tickets: VecSet<u64>,
        cancelled: bool,
    }

    /*
        The withdrawal capability struct represents the capability to withdrawal funds from a Lottery. This is 
        created and transferred to the creator of the lottery.
        @param id - The object id of the withdrawal capability object.
        @param lottery - The id of the Lottery object.
    */
    struct WithdrawalCapability has key {
        id: UID,
        lottery: ID, 
    }

    /*
        The lottery ticket bought by a player
        @param id - The object id of the withdrawal capability object.
        @param lottery - The id of the Lottery object.
        @param ticket_number - The ticket number bought
    */
    struct LotteryTicket has key {
        id: UID,
        lottery: ID,
        ticket_number: u64,
    }

    //==============================================================================================
    // Event structs - DO NOT MODIFY
    //==============================================================================================

    /*
        Event emitted when a Lottery is created.
        @param lottery - The id of the Lottery object.
    */
    struct LotteryCreated has copy, drop {
        lottery: ID,
    }

    /*
        Event emitted when a withdrawal is made from the Lottery
        @param lottery_id - The id of the Lottery object.
        @param amount - The amount withdrawn in MIST
        @param recipient - The recipient of the withdrawal
    */
    struct LotteryWithdrawal has copy, drop {
        lottery: ID,
        amount: u64,
        recipient: address,
    }

    /*
        Event emitted a ticket is bought for the lottery
        @param ticket_number - The ticket number bought
        @param lottery_id - The id of the Lottery object.
    */
    struct LotteryTicketBought has copy, drop {
        ticket_number: u64,
        lottery: ID,
    }

    /*
        Event emitted when there is a winner for the lottery
        @param winning_number - The winning number
        @param lottery_id - The id of the Lottery object.
    */
    struct LotteryWinner has copy, drop {
        winning_number: u64,
        lottery: ID,
    }

    //==============================================================================================
    // Functions
    //==============================================================================================

    /*
        Create a Lottery for the given NFT and recipient. Abort if the number of participants is 
        less than the minimum participant number, the range is less than the minimum range, the 
        start time is in the past, or the end time is before the start time. 
        @param nft - NFT prize for the lottery created
        @param participants - Minimum number of participants
        @param price - Price per ticket in lottery
        @param range - Upper limit for lottery numbers
        @param clock - Clock object
        @param start_time - Start time for lottery
        @param end_time - End time for lottery
        @param recipient - Address of recipient of WithdrawalCapability object minted
        @param ctx - Transaction context.
	*/
    public fun create<T: key + store>(
        nft: T, 
        participants: u64, 
        price: u64, 
        range: u64, 
        clock: &Clock, 
        start_time: u64, 
        end_time: u64, 
        recipient: address,
        ctx: &mut TxContext
    ) {
        
    }

    /*
        Withdraw the current balance from the lottery to the recipient. Abort if the lottery_cap 
        does not match the lottery, the lottery has been cancelled, or the lottery has not been run.
        @param lottery_cap - WithdrawalCapability object
        @param lottery - Lottery object
        @param recipient - Address of recipient for the withdrawal
        @param ctx - Transaction context.
	*/
    public fun withdraw<T: key + store>(
        lottery_cap: &WithdrawalCapability, 
        lottery: &mut Lottery<T>, 
        recipient: address, 
        ctx: &mut TxContext
    ) {
        
    }

    /*
        Buy a lottery ticket for the recipient. Anyone can buy a ticket number of their choosing. 
        Abort if the lottery has been cancelled, the lottery has already been run, the payment is 
        less than the price per ticket, the ticket number is greater than the range, or the ticket 
        number has already been bought. 
        @param ticket_number - The ticket number we wish to buy
        @param lottery - Lottery object
        @param payment - Payment in SUI for the ticket
        @param recipient - Address of recipient for the withdrawal
        @param ctx - Transaction context.
	*/
    public fun buy<T: key + store>(
        ticket_number: u64, 
        lottery: &mut Lottery<T>, 
        payment: &mut Coin<SUI>, 
        recipient: address, 
        ctx: &mut TxContext
    ) {
        
    }

    /*
        Generates the random number and ends the lottery with it. (DON'T MODIFY)
        @param lottery - Lottery object
        @param clock - Clock object
        @param ctx - Transaction context.
	*/
    public fun run<T: key + store>(
        lottery: &mut Lottery<T>, 
        clock: &Clock, 
        ctx: &mut TxContext
    ) {
        let winning_number = overmind::random::generate_number(lottery.range, ctx);
        run_internal(lottery, clock, winning_number)
    }

    /*
        Updates the lottery if a winner is found. Abort if the lottery has already been run, the lottery 
        has been cancelled, the lottery has not yet ended, or the lottery has not yet reached the 
        minimum number of participants.
        @param lottery - Lottery object
        @param clock - Clock object
	*/
    fun run_internal<T: key + store>(
        lottery: &mut Lottery<T>, 
        clock: &Clock,
        winning_number: u64
    ) {

    }
    
    /*
        Claim prize for the winning ticket. Abort if the lottery has not been run, the lottery 
        ticket does not match the lottery, the lottery has no NFT prize, or the lottery ticket is
        not the winning number.
        @param lottery - Lottery object
        @param ticket - Winning lottery ticket
        @param recipient - Recipient to receive the prize
	*/
    public fun claim_prize<T: key + store>(
        lottery: &mut Lottery<T>, 
        ticket: &LotteryTicket, 
        recipient: address
    ) {
        
    } 

    /*
        Cancels the lottery if it has not been cancelled already. Send the ticket cost back to the 
        recipient. Abort if the lottery cannot be cancelled, or if the ticket has already been 
        refunded. 
        @param lottery - Lottery object
        @param clock - Clock object
        @param ticket - Lottery ticket object
        @param recipient - Recipient to receive refund
        @param ctx - Transaction context.
	*/
    public fun refund<T: key + store>(
        lottery: &mut Lottery<T>, 
        clock: &Clock, 
        ticket: &LotteryTicket, 
        recipient: address, 
        ctx: &mut TxContext
    ) {
        
    }

    /*
        Cancels the lottery if it has not been cancelled already. Send the NFT to the recipient. 
        Abort if the lottery cannot be canceled, or if there is no NFT prize.
        @param lottery - Lottery object
        @param clock - Clock object
        @param recipient - Recipient to receive refund
        @param withdrawal_cap - WithdrawalCapability object
	*/
    public fun return_nft<T: key + store>(
        lottery: &mut Lottery<T>, 
        clock: &Clock, 
        recipient: address, 
        withdrawal_cap: WithdrawalCapability
    ) {
        
    }

    /*
        Destroy the given ticket and remove it from the lottery. Abort if the ticket is not found in 
        the lottery.
        @param lottery - Lottery the ticket was bought for
        @param ticket - Ticket to be burnt
	*/
    public fun burn_ticket<T: key + store>(
        lottery: &mut Lottery<T>,
        ticket: LotteryTicket
    ) {
        
    }

    //==============================================================================================
    // Helper functions - Add your helper functions here (if any)
    //==============================================================================================

    //==============================================================================================
    // Validation functions - Add your validation functions here (if any)
    //==============================================================================================
    
    //==============================================================================================
    // Tests
    //==============================================================================================
    
    #[test_only]
    use sui::test_scenario;
    #[test_only]
    use sui::test_utils::assert_eq;
    #[test_only]
    use overmind::test_utils::{Self};

    #[test]
    fun test_create_success_created_one_lottery() {
        let admin = @0xCAFE;
        let scenario_val = test_scenario::begin(admin);
        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;

        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                 test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        let tx = test_scenario::next_tx(scenario, admin);
        let expected_events_emitted = 1;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );

        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            
            assert_eq(lottery.participants, number_of_participants);
            assert_eq(lottery.price, price);
            assert_eq(lottery.range, 1000);
            assert_eq(lottery.start_time, start_time);
            assert_eq(lottery.end_time, end_time);
            assert!(option::is_some(&lottery.nft), 0);
            assert!(option::is_none(&lottery.winning_number), 0);
            assert_eq(vec_set::size(&lottery.tickets), 0);
            assert_eq(lottery.cancelled, false);
            assert_eq(balance::value(&lottery.balance), 0);

            let withdrawal_cap = test_scenario::take_from_sender<WithdrawalCapability>(scenario);
            
            assert_eq(withdrawal_cap.lottery, sui::object::id(&lottery));
            
            test_scenario::return_to_sender(scenario, withdrawal_cap);
            test_scenario::return_shared(lottery);
        };

        test_scenario::end(scenario_val);
    }

    #[test, expected_failure(abort_code = ENoWithdrawalCapability)]
    fun test_withdrawal_failure_without_withdrawal_capability() {
        let admin = @0xCAFE;
        let other = @0xFACE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;

        let scenario_val = test_scenario::begin(admin);

        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                 test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, other);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let withdrawal_cap = WithdrawalCapability {
                id: sui::object::new(test_scenario::ctx(scenario)),
                lottery: sui::object::id_from_address(other),
            };

            withdraw(&withdrawal_cap, &mut lottery, other, test_scenario::ctx(scenario));

            test_scenario::return_to_sender(scenario, withdrawal_cap);
            test_scenario::return_shared(lottery);
        };

        test_scenario::end(scenario_val);
    }

    #[test, expected_failure(abort_code = ELotteryHasNoWinningNumber)]
    fun test_withdrawal_failure_without_running_lottery() {
        let admin = @0xCAFE;
        
        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;

        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                 test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let withdrawal_cap = test_scenario::take_from_sender<WithdrawalCapability>(scenario);
            
            withdraw(&withdrawal_cap, &mut lottery, admin, test_scenario::ctx(scenario));

            test_scenario::return_to_sender(scenario, withdrawal_cap);
            test_scenario::return_shared(lottery);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_buy_success_receive_one_ticket() {
        let admin = @0xCAFE;
        let player = @0xFACE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;
        let ticket_number = 10;

        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                 test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        let tx = test_scenario::next_tx(scenario, player);
        let expected_events_emitted = 1;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );

        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price, test_scenario::ctx(scenario));
            buy(ticket_number, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);
        };

        let tx = test_scenario::next_tx(scenario, player);
        let expected_events_emitted = 1;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );

        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let ticket = test_scenario::take_from_sender<LotteryTicket>(scenario);
            assert_eq(vec_set::contains(&lottery.tickets, &ticket_number), true);
            assert_eq(ticket.lottery, sui::object::id(&lottery));
            assert_eq(ticket.ticket_number, ticket_number);
            assert_eq(balance::value(&lottery.balance), price);
            test_scenario::return_shared(lottery);
            test_scenario::return_to_sender(scenario, ticket);
        };

        test_scenario::end(scenario_val);
    }
    
    #[test, expected_failure(abort_code = EInsufficientFunds)]
    fun test_buy_failure_insufficient_funds() {
        let admin = @0xCAFE;
        let player = @0xFACE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;
        let ticket_number = 10;

        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                 test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price - 1, test_scenario::ctx(scenario));
            buy(ticket_number, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);
        };
    
        test_scenario::end(scenario_val);
    }

    #[test, expected_failure(abort_code = EInvalidRange)]
    fun test_buy_failure_invalid_range() {
        let admin = @0xCAFE;
        let player = @0xFACE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;

        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                 test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price, test_scenario::ctx(scenario));
            buy(1000 + 1, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);
        };
    
        test_scenario::end(scenario_val);
    }

    #[test, expected_failure(abort_code = ETicketAlreadyGone)]
    fun test_buy_failure_ticket_already_gone() {
        let admin = @0xCAFE;
        let player = @0xFACE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;
        let ticket_number = 10;

        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                 test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price, test_scenario::ctx(scenario));
            buy(ticket_number, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price, test_scenario::ctx(scenario));
            buy(ticket_number, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_run_success_generate_winning_number() {
        let admin = @0xCAFE;
        let player = @0xFACE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;
        let winning_number = 10;
        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        let tx = test_scenario::next_tx(scenario, player);
        let expected_events_emitted = 1;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );
        
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price, test_scenario::ctx(scenario));
            buy(winning_number, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);
        };

        let tx = test_scenario::next_tx(scenario, player);
        let expected_events_emitted = 1;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );

        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            clock::increment_for_testing(&mut clock, end_time + 1);
            run_internal(&mut lottery, &clock, winning_number);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(lottery);            
        };

        let tx = test_scenario::next_tx(scenario, player);
        let expected_events_emitted = 1;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );

        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let ticket = test_scenario::take_from_sender<LotteryTicket>(scenario);
            assert_eq(*option::borrow(&lottery.winning_number), winning_number);
            test_scenario::return_to_sender(scenario, ticket);
            test_scenario::return_shared(lottery);            
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_run_success_run_lottery_and_claim_prize() {
        let admin = @0xCAFE;
        let player = @0xFACE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;
        let winning_number = 10;
        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price, test_scenario::ctx(scenario));
            buy(winning_number, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            clock::increment_for_testing(&mut clock, end_time + 1);
            run_internal(&mut lottery, &clock, winning_number);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(lottery);            
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let ticket = test_scenario::take_from_sender<LotteryTicket>(scenario);
            claim_prize(&mut lottery, &ticket, player);
            test_scenario::return_to_sender(scenario, ticket);
            test_scenario::return_shared(lottery);            
        };

        let tx = test_scenario::next_tx(scenario, player);
        let expected_events_emitted = 0;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );

        {
            let nft = test_scenario::take_from_sender<test_utils::TestNFT>(scenario);
            test_scenario::return_to_sender(scenario, nft);
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_run_success_run_lottery_and_withdraw_profits() {
        let admin = @0xCAFE;
        let player = @0xFACE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;
        let winning_number = 10;
        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        let tx = test_scenario::next_tx(scenario, player);
        let expected_events_emitted = 1;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );

        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price, test_scenario::ctx(scenario));
            buy(winning_number, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);
        };

        let tx = test_scenario::next_tx(scenario, player);
        let expected_events_emitted = 1;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );

        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            clock::increment_for_testing(&mut clock, end_time + 1);
            run_internal(&mut lottery, &clock, winning_number);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(lottery);            
        };

        let tx = test_scenario::next_tx(scenario, admin);
        let expected_events_emitted = 1;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );

        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let withdrawal_cap = test_scenario::take_from_sender<WithdrawalCapability>(scenario);
            
            withdraw(&withdrawal_cap, &mut lottery, admin, test_scenario::ctx(scenario));
            
            test_scenario::return_to_sender(scenario, withdrawal_cap);
            test_scenario::return_shared(lottery);            
        };

        let tx = test_scenario::next_tx(scenario, admin);
        let expected_events_emitted = 1;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );

        {
            let coins = test_scenario::take_from_sender<Coin<SUI>>(scenario);
            let coin_balance = coin::balance(&coins);
            assert_eq(balance::value(coin_balance), price);
            test_scenario::return_to_sender(scenario, coins);
        };

        test_scenario::end(scenario_val);
    }

    #[test, expected_failure(abort_code = EInvalidLottery)]
    fun test_run_failure_claim_prize_with_invalid_ticket() {
        let admin = @0xCAFE;
        let player = @0xFACE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;
        let winning_number = 10;
        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };
        
        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price, test_scenario::ctx(scenario));
            buy(winning_number, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            clock::increment_for_testing(&mut clock, end_time + 1);
            run_internal(&mut lottery, &clock, winning_number);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(lottery);            
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            
            let uid = sui::object::new(test_scenario::ctx(scenario));
            let lottery_id = sui::object::uid_as_inner(&uid);
            let ticket = LotteryTicket {
                id: sui::object::new(test_scenario::ctx(scenario)),
                lottery: *lottery_id,
                ticket_number: winning_number,
            };
            
            sui::object::delete(uid);
            claim_prize(&mut lottery, &ticket, player);
            test_scenario::return_to_sender(scenario, ticket);
            test_scenario::return_shared(lottery);            
        };
    
        test_scenario::end(scenario_val);
    }

    #[test, expected_failure(abort_code = ELotteryHasNoWinningNumber)]
    fun test_run_failure_claim_prize_with_lottery_not_run() {
        let admin = @0xCAFE;
        let player = @0xFACE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;
        let winning_number = 10;
        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price, test_scenario::ctx(scenario));
            buy(winning_number, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let ticket = test_scenario::take_from_sender<LotteryTicket>(scenario);
            claim_prize(&mut lottery, &ticket, player);
            test_scenario::return_to_sender(scenario, ticket);
            test_scenario::return_shared(lottery);            
        };
    
        test_scenario::end(scenario_val);
    }

    #[test, expected_failure(abort_code = ENoPrizeAvailable)]
    fun test_run_failure_claim_prize_twice() {
        let admin = @0xCAFE;
        let player = @0xFACE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;
        let winning_number = 10;
        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price, test_scenario::ctx(scenario));
            buy(winning_number, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            clock::increment_for_testing(&mut clock, end_time + 1);
            run_internal(&mut lottery, &clock, winning_number);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(lottery);            
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let ticket = test_scenario::take_from_sender<LotteryTicket>(scenario);
            claim_prize(&mut lottery, &ticket, player);
            test_scenario::return_to_sender(scenario, ticket);
            test_scenario::return_shared(lottery);            
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let ticket = test_scenario::take_from_sender<LotteryTicket>(scenario);
            claim_prize(&mut lottery, &ticket, player);
            test_scenario::return_to_sender(scenario, ticket);
            test_scenario::return_shared(lottery);   
        };

        test_scenario::end(scenario_val);
    }

    #[test, expected_failure(abort_code = ENotWinningNumber)]
    fun test_run_failureclaim_with_not_winning_ticket() {
        let admin = @0xCAFE;
        let player = @0xFACE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;
        let winning_number = 10;
        let not_winning_number = 11;
        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price, test_scenario::ctx(scenario));
            buy(winning_number, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            clock::increment_for_testing(&mut clock, end_time + 1);
            run_internal(&mut lottery, &clock, winning_number);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(lottery);            
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);    

            let ticket = LotteryTicket {
                id: sui::object::new(test_scenario::ctx(scenario)),
                lottery: sui::object::id(&lottery),
                ticket_number: not_winning_number,
            };
            
            claim_prize(&mut lottery, &ticket, player);
            
            let LotteryTicket {
                id,
                lottery: _,
                ticket_number: _,
            } = ticket;

            sui::object::delete(id);

            test_scenario::return_shared(lottery);            
        };
    
        test_scenario::end(scenario_val);
    }

    #[test, expected_failure(abort_code = ENotCancelled)]
    fun test_refund_failure_when_not_cancelled() {
        let admin = @0xCAFE;
        let player = @0xFACE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;
        let winning_number = 10;
        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price, test_scenario::ctx(scenario));
            buy(winning_number, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);           
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            clock::increment_for_testing(&mut clock, end_time + 1);
            run_internal(&mut lottery, &clock, winning_number);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(lottery);            
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let ticket = test_scenario::take_from_sender<LotteryTicket>(scenario);

            refund(&mut lottery, &clock, &ticket, player, test_scenario::ctx(scenario));

            test_scenario::return_to_sender(scenario, ticket);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(lottery);            
        };
        
        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_cancel_success_initiate_cancellation_with_refund() {
        let admin = @0xCAFE;
        let player = @0xFACE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;
        let winning_number = 10;
        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price, test_scenario::ctx(scenario));
            buy(winning_number, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);           
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let ticket = test_scenario::take_from_sender<LotteryTicket>(scenario);

            clock::increment_for_testing(&mut clock, end_time + 24 * 60 * 60 * 1000 * 7 + 1);

            refund(&mut lottery, &clock, &ticket, player, test_scenario::ctx(scenario));

            test_scenario::return_to_sender(scenario, ticket);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(lottery);            
        };
        
        let tx = test_scenario::next_tx(scenario, player);
        let expected_events_emitted = 0;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );

        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            assert_eq(lottery.cancelled, true);
            assert_eq(vec_set::contains(&lottery.tickets, &winning_number), false);
            let coins = test_scenario::take_from_sender<Coin<SUI>>(scenario);
            let coin_balance = coin::balance(&coins);
            assert_eq(balance::value(coin_balance), price);
            test_scenario::return_to_sender(scenario, coins);
            test_scenario::return_shared(lottery);           
        };

        test_scenario::end(scenario_val);
    }

    #[test, expected_failure(abort_code = ETicketNotAvailable)]
    fun test_refund_failure_with_invalid_ticket_number() {
        let admin = @0xCAFE;
        let player = @0xFACE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;
        let winning_number = 10;
        let not_winning_number = 11;

        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price, test_scenario::ctx(scenario));
            buy(winning_number, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);           
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let ticket = LotteryTicket {
                id: sui::object::new(test_scenario::ctx(scenario)),
                lottery: sui::object::id(&lottery),
                ticket_number: not_winning_number,
            };
            
            clock::increment_for_testing(&mut clock, end_time + 24 * 60 * 60 * 1000 * 7 + 1);

            refund(&mut lottery, &clock, &ticket, player, test_scenario::ctx(scenario));
        
            test_scenario::return_to_sender(scenario, ticket);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(lottery);            
        };

        test_scenario::end(scenario_val);
    }

    #[test, expected_failure(abort_code = ELotteryCancelled)]
    fun test_withdraw_failure_when_lottery_cancelled() {
        let admin = @0xCAFE;
        let player = @0xFACE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;
        let winning_number = 10;
        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price, test_scenario::ctx(scenario));
            buy(winning_number, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);           
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let ticket = test_scenario::take_from_sender<LotteryTicket>(scenario);

            clock::increment_for_testing(&mut clock, end_time + 24 * 60 * 60 * 1000 * 7 + 1);

            refund(&mut lottery, &clock, &ticket, player, test_scenario::ctx(scenario));

            test_scenario::return_to_sender(scenario, ticket);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(lottery);            
        };
        
        test_scenario::next_tx(scenario, admin);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let withdrawal_cap = test_scenario::take_from_sender<WithdrawalCapability>(scenario);

            withdraw(&withdrawal_cap, &mut lottery, admin, test_scenario::ctx(scenario));

            test_scenario::return_to_sender(scenario, withdrawal_cap);
            test_scenario::return_shared(lottery);
        };

        test_scenario::end(scenario_val);
    }

    #[test, expected_failure(abort_code = ELotteryCancelled)]
    fun test_buy_failure_when_lottery_cancelled() {
        let admin = @0xCAFE;
        let player = @0xFACE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;
        let winning_number = 10;
        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price, test_scenario::ctx(scenario));
            buy(winning_number, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);           
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let ticket = test_scenario::take_from_sender<LotteryTicket>(scenario);

            clock::increment_for_testing(&mut clock, end_time + 24 * 60 * 60 * 1000 * 7 + 1);

            refund(&mut lottery, &clock,  &ticket, player, test_scenario::ctx(scenario));

            test_scenario::return_to_sender(scenario, ticket);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(lottery);            
        };
        
        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price, test_scenario::ctx(scenario));
            buy(winning_number, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);           
        };

        test_scenario::end(scenario_val);
    }

    #[test, expected_failure(abort_code = ENotCancelled)]
    fun test_refund_failure_return_nft_when_not_cancelled() {
        let admin = @0xCAFE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;
        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let withdrawal_cap = test_scenario::take_from_sender<WithdrawalCapability>(scenario);

            return_nft(&mut lottery, &clock, admin, withdrawal_cap);

            test_scenario::return_shared(clock);
            test_scenario::return_shared(lottery);            
        };

        test_scenario::end(scenario_val);
    }

    #[test]
    fun test_return_nft_success_nft_transferred_back() {
        let admin = @0xCAFE;
        let player = @0xFACE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;
        let winning_number = 10;
        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price, test_scenario::ctx(scenario));
            buy(winning_number, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);           
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let ticket = test_scenario::take_from_sender<LotteryTicket>(scenario);

            clock::increment_for_testing(&mut clock, end_time + 24 * 60 * 60 * 1000 * 7 + 1);

            refund(&mut lottery, &clock, &ticket, player, test_scenario::ctx(scenario));

            test_scenario::return_to_sender(scenario, ticket);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(lottery);            
        };
        
        let tx = test_scenario::next_tx(scenario, admin);
        let expected_events_emitted = 0;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );

        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let withdrawal_cap = test_scenario::take_from_sender<WithdrawalCapability>(scenario);

            return_nft(&mut lottery, &clock, admin, withdrawal_cap);

            test_scenario::return_shared(clock);
            test_scenario::return_shared(lottery);         
        };
        

        let tx = test_scenario::next_tx(scenario, admin);
        let expected_events_emitted = 0;
        assert_eq(
            test_scenario::num_user_events(&tx),
            expected_events_emitted
        );

        {
            let nft = test_scenario::take_from_sender<test_utils::TestNFT>(scenario);
            test_scenario::return_to_sender(scenario, nft);
        };

        test_scenario::end(scenario_val);
    }

    #[test, expected_failure]
    fun test_refund_nft_success_should_burn_withdrawal_capability() {
        let admin = @0xCAFE;
        let player = @0xFACE;

        let number_of_participants = 1;
        let price = 10;
        let start_time = 0;
        let end_time = 10;
        let winning_number = 10;
        let scenario_val = test_scenario::begin(admin);
        
        let scenario = &mut scenario_val;
        {
            test_utils::setup(scenario);
        };

        test_scenario::next_tx(scenario, admin);
        {
            let nft = test_utils::create_nft(test_scenario::ctx(scenario));      
            let clock = test_scenario::take_shared<Clock>(scenario);
            
            create(
                nft, 
                number_of_participants, 
                price, 
                1000, 
                &clock,
                start_time, 
                end_time, 
                admin,
                test_scenario::ctx(scenario)
            );

            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let payment = coin::mint_for_testing<SUI>(price, test_scenario::ctx(scenario));
            buy(winning_number, &mut lottery, &mut payment, player, test_scenario::ctx(scenario));
            coin::burn_for_testing(payment);
            test_scenario::return_shared(lottery);           
        };

        test_scenario::next_tx(scenario, player);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let ticket = test_scenario::take_from_sender<LotteryTicket>(scenario);

            clock::increment_for_testing(&mut clock, end_time + 24 * 60 * 60 * 1000 * 7 + 1);

            refund(&mut lottery, &clock,&ticket, player, test_scenario::ctx(scenario));

            test_scenario::return_to_sender(scenario, ticket);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(lottery);            
        };
        
        test_scenario::next_tx(scenario, admin);
        {
            let lottery = test_scenario::take_shared<Lottery<test_utils::TestNFT>>(scenario);
            let clock = test_scenario::take_shared<Clock>(scenario);
            let withdrawal_cap = test_scenario::take_from_sender<WithdrawalCapability>(scenario);

            return_nft(&mut lottery, &clock, admin, withdrawal_cap);

            test_scenario::return_shared(clock);
            test_scenario::return_shared(lottery);         
        };

        test_scenario::next_tx(scenario, admin);
        {
            let withdrawal_cap = test_scenario::take_from_sender<WithdrawalCapability>(scenario);
            test_scenario::return_to_sender(scenario, withdrawal_cap);
        };

        test_scenario::end(scenario_val);
    }
}

module overmind::random {
    use sui::tx_context::{Self, TxContext};
    use overmind::vector_utils::from_be_bytes;

    public fun generate_pseudorandom(ctx: &mut TxContext): vector<u8> {
        std::bcs::to_bytes(&tx_context::fresh_object_address(ctx))
    }

    public fun generate_number(range: u64, ctx: &mut TxContext) : u64 {
        from_be_bytes(generate_pseudorandom(ctx)) % range
    }
}

#[test_only]
module overmind::test_utils {
    use sui::object::UID;
    use sui::tx_context::TxContext;
    use sui::clock;
    use sui::test_scenario::{Self, Scenario};

    struct TestNFT has store, key {
        id: UID,
    }

    public fun setup(scenario: &mut Scenario) {
        clock::share_for_testing(clock::create_for_testing(test_scenario::ctx(scenario)));
    }

    public fun create_nft(ctx: &mut TxContext) : TestNFT {
        TestNFT {
            id: sui::object::new(ctx),
        }
    }
}
