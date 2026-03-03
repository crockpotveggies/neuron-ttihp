//------------------------------------------------------------------------------------------------//
// Generalized Ready-Valid Interface
//------------------------------------------------------------------------------------------------//
interface rv_if #(

    // The rv_payload type is parameterized here.
    // NOTE
    //  The rv_payload type must be a packed type.
    //  This allows handy assumptions and shortcuts for attached rv_* modules.
    parameter type RV_PAYLOAD_T = logic  // default to single bit

) (

    // NONE - Clockless

);


    //--------------------------------------------------------------------------------------------//
    // Interface Members
    //--------------------------------------------------------------------------------------------//

    // Receiver is ready to receive rv_payload.
    logic ready;

    // Transmitter is sending valid rv_payload.
    logic valid;

    // Payload, transferred when and only when ready==valid==1
    RV_PAYLOAD_T rv_payload;


    //--------------------------------------------------------------------------------------------//
    // Modport Definitions
    // Note: The 'tx' and 'rx' modports are the preferred names,
    //--------------------------------------------------------------------------------------------//

    // Transmit modport, primary driver
    modport tx          (                   input  ready, output valid, rv_payload );
 
    // Receive modport, primary receiver
    modport rx          (                   output ready, input  valid, rv_payload );
 
    // Monitor modport, for snooping transfers.
    modport monitor    (                    input  ready, input  valid, rv_payload );
 

    //--------------------------------------------------------------------------------------------//
    // Assertions (Clockless)
    //--------------------------------------------------------------------------------------------//

    // NOTE    //
    //    + When the <producer> has payload to transfer, it asserts the payload and valid,
    //      independently of the value of the <consumer>'s ready.
    //
    //    + When the <consumer> is able to accept a transfer it shall assert ready.
    //      The <consumer> may wait until the <producer> has asserted valid before asserting ready.
    //      This provides the <consumer> with the ability to inspect payload before accepting it.
    //
    //    + When valid and ready are asserted, the <consumer> shall consume the payload and the transfer is completed.
    //
    //    + When a transfer has completed and the <producer> has more payload to transfer,
    //      the <producer> <shall or may> assert the next payload to transfer and leave valid high.
    //      This provides the ability to do back to back transfers. 
    //
    //    + When a transfer has completed and the <producer> does not wish to do a back-to-back transfer,
    //      the <producer> shall de-asserts valid.  

    // NOTE
    //  We use the labels to indicate which party is responsible for satisfying each assertion.
    //  DES_ASSERT_tx_* -> the transmitter must ensure this condition is true
    //  DES_ASSERT_rx_* -> the receiver must ensure this condition is true

    // Guard the assertions to allow them to be turned off.
/*    `ifndef SVA_OFF

    // Ready is driven to a known value.
    DES_ASSERT_rx_ready_is_driven : assert property ( !$isunknown(ready) )
        else $error("DES_ASSERT_rx_ready_is_driven: ready signal is unknown");

    // Valid is driven to a known value.
    DES_ASSERT_tx_valid_is_driven : assert property ( !$isunknown(valid) )
        else $error("DES_ASSERT_tx_valid_is_driven: valid signal is unknown");

    // If valid is asserted, then payload is driven to a known value.
    DES_ASSERT_tx_rv_payload_is_driven : assert property ( valid |-> !$isunknown(rv_payload) )
        else $error("DES_ASSERT_tx_rv_payload_is_driven: rv_payload is unknown when valid is asserted");

    // Transfer occurs when both ready and valid are asserted.
    DES_ASSERT_transfer_condition : assert property ( (ready && valid) |-> $rise(1'b1) )
        else $error("DES_ASSERT_transfer_condition: Transfer detected (ready && valid)");

    //------------------------------------------------//
    // Cover all conditions for verification completeness

    `ifndef SVA_OFF_COVER
    DES_COVER_rx_ready_is_driven       : cover property ( !$isunknown(ready) );
    DES_COVER_tx_valid_is_driven       : cover property ( !$isunknown(valid) );
    DES_COVER_tx_rv_payload_is_driven  : cover property ( valid && !$isunknown(rv_payload) );
    DES_COVER_transfer_occurs          : cover property ( ready && valid );
    DES_COVER_tx_valid_only            : cover property ( valid && !ready );
    DES_COVER_rx_ready_only            : cover property ( !valid && ready );
    DES_COVER_idle_state               : cover property ( !valid && !ready );
    `endif // SVA_OFF_COVER
    `endif // SVA_OFF
*/

endinterface
