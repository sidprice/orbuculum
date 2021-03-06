`default_nettype none

// dbgIF
// =====
// 
// Working from ARM Debug Interface Architecture Specification ADIv5.0 to ADIv5.2
//
// Debug interface covering JTAG, SWJ and SWD use cases.
// Also deals with power pins.
//
// This gateware is under BSD licence.
//
// Commands are loaded by putting the command id into command, setting any registers and then
// taking 'go' true. 'done' will go false when the command has started, then go should be
// returned false. 'done' will go true when the command completes. err will be set for errors.
// For streams (specifically CMD_TRANSACT only) 'go' can be taken true again to prime the next
// transfer.
//
//  CMD_RESET       : Reset target, return after timeout or when target is out of reset.
//                    Wait for number of uS set via CMD_SET_RST_TMR, or 10mS if no explicit
//                    time has been set.  Then wait until reset pin returns high, or a guard
//                    period the same as the reset period expires.
//
//  CMD_PINS_WRITE  : Go to SWJ mode and write pins specified in pinsin[7:0], masked
//                    by pinsin[15:8], wait and then return pins in pinsout[7:0].
//                    dwrite is the time in uS to wait. If dwrite is zero then the period to
//                    wait is one target interface clock half-cycle.
//                          Bit Writable    Name              Notes                          
//                           0      Y     SWCLK/TCK
//                           1      Y     SWDIO/TMS
//                           2      Y     TDI
//                           3            TDO
//                           4      Y     SWWR          1==Output SPEC EXTENSION
//                           5            1'b1
//                           6            nRESET_STATE     SPEC EXTENSION
//                           7      Y     nRESET
//
//  CMD_TRANSACT    : Execute command transaction on target interface.
//                          addr32  Bits 2 & 3 of address
//                          rnw     Read(1) not Write(0)
//                          apndp   ap(1) not dp(0)
//                          ack     returned ack from command
//                          dwrite  any data to write
//                          dread   any data returned
//
//  CMD_SET_SWD     : Set interface to SWD mode.
//
//  CMD_SET_JTAG    : Set interface to JTAG mode.
//
//  CMD_SET_SWJ     : Set interface to SWJ mode.
//
//  CMD_SET_PWRDOWN : Set interface to power down.
//
//  CMD_SET_CLKDIV  : Set clock divisor for target interface (in dwrite).
//
//  CMD_SET_CFG     : Set turnaround clock ticks and dataPhase for SWD mode
//                          dwrite[1:0]  turnaround-1 (1..4 cycles)
//                          drwrite[2]   dataphase (cooloff of 32 additional bits on WAIT/FAULT)
//
//  CMD_WAIT        : Wait for prescribed number of uS in dwrite
//
//  CMD_CLR_ERR     : Clear error status
//
//  CMD_SET_RST_TMR : Set reset and reset guard time in uS
//

module dbgIF #(parameter CLK_FREQ=60000000, parameter DEFAULT_RST_TIMEOUT_USEC=300) (
		input             rst,
                input             clk,
                
        // Gross control, power etc.
                input             vsen,            // When 1, provide power to VS (pins 11 & 13 on 20 pin header)
                input             vdrive,          // When 1, provide power to Vdrive (pin 1 on 10 & 20 pin header)

	// Downwards interface to the pins
                input             swdi,            // DIO pin from target
                output            tms_swdo,        // TMS or DIO pin to target when in SWD mode
                output            swwr,            // Direction of DIO pin when in SWD mode
                output reg        tck_swclk,       // Clock pin to target
                output            tdi,             // TDI pin to target
                input             tdo_swo,         // TDO/SWO pin from target
                input             tgt_reset_state, // Current state of tgt_reset 

                output            tgt_reset_pin,   // Output pin to pull target reset low
                output            nvsen_pin,       // Output pin to control vsen
                output            nvdrive_pin,     // Output pin to control vdrive

	// Interface to command controller
                input [1:0]       addr32,          // Address bits 3:2 for message
                input             rnw,             // Set for read, clear for write
                input             apndp,           // AP(1) or DP(0) access?
                output [2:0]      ack,             // Most recent ack status
                input  [31:0]     dwrite,          // Most recent data or parameter to write
                output [31:0]     dread,           // Data read from target
                input  [15:0]     pinsin,          // Pin setting information to target (upper 8 bits mask)
                output [7:0]      pinsout,         // Pin information from target 
               
output c,
        // Event triggers and responses
                input [3:0]       command,         // Command to be performed 
                input             go,              // Trigger
                output            done,            // Response
                output reg        perr             // Indicator of a error in the transfer
	      );

   parameter TICKS_PER_USEC=CLK_FREQ/1000000;
   parameter DEFAULT_IF_TICKS_PER_CLK=32;
   
   // Control commands
   parameter CMD_RESET       = 0;
   parameter CMD_PINS_WRITE  = 1;
   parameter CMD_TRANSACT    = 2;
   parameter CMD_SET_SWD     = 3;
   parameter CMD_SET_JTAG    = 4;
   parameter CMD_SET_SWJ     = 5;
   parameter CMD_SET_PWRDOWN = 6;
   parameter CMD_SET_CLKDIV  = 7;
   parameter CMD_SET_CFG     = 8;
   parameter CMD_WAIT        = 9;
   parameter CMD_CLR_ERR     = 10;
   parameter CMD_SET_RST_TMR = 11;

   // Comms modes
   parameter MODE_PWRDOWN = 0;
   parameter MODE_SWJ     = 1;
   parameter MODE_SWD     = 2;
   parameter MODE_JTAG    = 3;
                      
   // Internals =======================================================================
   reg [10:0]                     cdivcount;       // divisor for external clock
   reg [10:0]                     usecsdiv;        // Divider for usec
   reg [31:0]                     usecs;           // usec continuous counter
   reg [15:0]                     modechange;      // Shift register for changing mode
   reg [22:0]                     usecsdown;       // usec downcounter
   
   reg [1:0]                      cdc_go;          // Clock domain crossed go
   reg                            if_go;           // Go to inferior
      
   // Pins driven by swd (MODE_SWD)
   wire                           swd_swdo;
   wire                           swd_swclk;
   wire                           swd_swwr;
   wire [2:0]                     swd_ack;
   wire [31:0]                    swd_dread;
   wire                           swd_perr;
   wire                           swd_idle;

   // Pins driven by pin_write (MODE_SWJ)
   reg                           pinw_swclk;
   reg                           pinw_swdo;
   reg                           pinw_nreset;
   reg                           pinw_tdi;
   reg                           pinw_swwr;

   assign nvsen_pin     = ~vsen;
   assign nvdrive_pin   = ~vdrive;
   
   // Mux submodule outputs to this module outputs
   assign tms_swdo  = (active_mode==MODE_SWD)?swd_swdo  :(active_mode==MODE_SWJ)?pinw_swdo :1'b0;
   assign swwr      = (active_mode==MODE_SWD)?swd_swwr  :(active_mode==MODE_SWJ)?pinw_swwr :1'b1;
   assign tdi       = (active_mode==MODE_SWD)?1'b1      :(active_mode==MODE_SWJ)?pinw_tdi  :1'b1;
   assign ack       = (active_mode==MODE_SWD)?swd_ack   :0;
   assign dread     = (active_mode==MODE_SWD)?swd_dread :0;

   assign done = (dbg_state==ST_DBG_IDLE);

   swdIF swd_instance (
	      .rst(rst),
              .clk(clk),
                       
              .swdi(swdi),
              .swdo(swd_swdo),
              .swclk(next_swclk),
              .swwr(swd_swwr),
              .turnaround(turnaround),
              .dataphase(dataphase),
                
              .addr32(addr32),
              .rnw(rnw),
              .apndp(apndp),
              .dwrite(dwrite[31:0]),
              .ack(swd_ack),
              .dread(swd_dread),
              .perr(swd_perr),

              .c(c),
              .go(if_go && (active_mode==MODE_SWD)),
              .idle(swd_idle)
	      );

   reg [10:0]                     clkDiv;          // Divisor per clock change to target
   reg [1:0]                      turnaround;      // Number of cycles for turnaround when in SWD mode
   reg                            dataphase;       // Indicator of if a dataphase is needed on WAIT/FAULT
   reg [22:0]                     rst_timeout;     // Default time for a reset
   
   reg [1:0]                      active_mode;     // Mode that the interface is actually in
   reg [1:0]                      commanded_mode;  // Mode that the interface is requested to be in
   reg [3:0]                      dbg_state;       // Current state of debug handler
   reg [6:0]                      switch_step;     // Stepping through mode switch
   reg                            next_swclk;      // swclk pre-calcuation

   parameter ST_DBG_IDLE                 = 0;
   parameter ST_DBG_RESETTING            = 1;
   parameter ST_DBG_RESET_GUARD          = 2;
   parameter ST_DBG_PINWRITE_WAIT        = 3;
   parameter ST_DBG_WAIT_INFERIOR_START  = 4;
   parameter ST_DBG_WAIT_INFERIOR_FINISH = 5;
   parameter ST_DBG_WAIT_GOCLEAR         = 6;
   parameter ST_DBG_WAIT_TIMEOUT         = 7;
   parameter ST_DBG_WAIT_CLKCHANGE       = 8;
   parameter ST_DBG_ESTABLISH_MODE       = 9;

   // Active low reset on target
   assign tgt_reset_pin = (active_mode==MODE_SWJ)?pinw_nreset:(dbg_state!=ST_DBG_RESETTING);

   // Always reflect current state of pins
   assign pinsout={ tgt_reset_pin, tgt_reset_state, 1'b1, swwr, tdo_swo, tdi, swdi, tck_swclk };

   // Edge flagging
   wire                           risingedge=((!cdivcount) && (!next_swclk));
   wire                           fallingedge=((!cdivcount) && (next_swclk));
   wire                           anedge=(!cdivcount);
   
   always @(posedge clk, posedge rst)

     begin
	if (rst)
	  begin
             cdc_go      <= 0;
             dataphase   <= 0;
             turnaround  <= 0;
             next_swclk  <= 1;
             tck_swclk   <= 1;
             cdivcount   <= 1;
             clkDiv      <= DEFAULT_IF_TICKS_PER_CLK;
             rst_timeout <= DEFAULT_RST_TIMEOUT_USEC;
             dbg_state   <= ST_DBG_IDLE;
             perr        <= 0;
             if_go       <= 0;
             active_mode    <= MODE_PWRDOWN;
             commanded_mode <= MODE_PWRDOWN;
	  end
	else
          begin
             // CDC the go signal
             cdc_go <= {cdc_go[0],go};
             
             // Run clock for sub-modules constantly while not idle
             cdivcount <= cdivcount-1;
             if (!cdivcount)
               begin
                  next_swclk <= (dbg_state!=ST_DBG_IDLE)?~next_swclk:1'b0;
                  cdivcount <= clkDiv;
               end

             if (usecsdiv)
               usecsdiv <= usecsdiv - 1;
             else
               begin
                  usecs <= usecs + 1;
                  usecsdiv <= TICKS_PER_USEC;
                  usecsdown <= usecsdown - 1;
               end

             // This is deliberately registered to keep it in sync with inferior timing
             tck_swclk<=next_swclk;
             
             case(dbg_state)
               ST_DBG_IDLE: // Command request ========================================================
                 if ((cdc_go==2'b11) && (!next_swclk))
                   begin
                      // This is only processed at a rising clock edge
                      perr       <= 0;
                      pinw_swdo  <= 1'b0;
                      pinw_swclk <= 1'b1;
                      pinw_swwr  <= 1'b1;
                      
                      case(command)
                        CMD_PINS_WRITE: // Write pins specified in call -----------
                          begin
                             active_mode <= MODE_SWJ;
                             usecsdown   <= dwrite[31:0];
                             
                             // Update these bits if they're requested for updating
                             pinw_swclk  <= pinsin[8] ?pinsin[0]:1'b1;  // This is about to become 1, so make it so here
                             pinw_swdo   <= pinsin[9] ?pinsin[1]:tms_swdo;
                             pinw_tdi    <= pinsin[10]?pinsin[2]:tdi;
                             pinw_swwr   <= pinsin[12]?pinsin[4]:swwr;
                             pinw_nreset <= pinsin[15]?pinsin[7]:tgt_reset_pin;
                             
                             dbg_state   <= (dwrite)?ST_DBG_WAIT_TIMEOUT:ST_DBG_WAIT_CLKCHANGE;
                             
                          end // case: CMD_PINS_WRITE
                        
                        CMD_RESET: // Reset target ---------------------------------
                          begin
                             usecsdown <= rst_timeout;
                             dbg_state <= ST_DBG_RESETTING;
                          end
                        
                        CMD_TRANSACT: // Execute transaction on target interface ---
                          begin
                             if_go       <= 1'b1;
                             active_mode <= commanded_mode;
                             dbg_state   <= ST_DBG_WAIT_INFERIOR_START;
                          end
                        
                        CMD_SET_SWD: // Set SWD mode -------------------------------
                          begin
                             commanded_mode <= MODE_SWD;
                             active_mode    <= MODE_SWJ;
                             pinw_swclk     <= 1;
                             pinw_swdo      <= 0;
                             pinw_swwr      <= 1;                             
                             switch_step    <= 0;
                             modechange     <= 16'he79e;
                             dbg_state      <= ST_DBG_ESTABLISH_MODE;
                          end
                          
                        CMD_SET_JTAG: // Set JTAG mode -----------------------------
                          begin
                             commanded_mode <= MODE_JTAG;
                             active_mode    <= MODE_SWJ;
                             pinw_swclk     <= 1;
                             pinw_swdo      <= 0;
                             pinw_swwr      <= 1;                             
                             switch_step    <= 0;
                             modechange     <= 16'hE73C;
                             dbg_state      <= ST_DBG_ESTABLISH_MODE;
                          end
                        
                        CMD_SET_SWJ: // Set SWJ mode -------------------------------
                          begin
                             commanded_mode <= MODE_SWJ;
                             active_mode    <= MODE_SWJ;
                             dbg_state      <= ST_DBG_WAIT_GOCLEAR;
                          end

                        CMD_SET_PWRDOWN: // Set Power Down mode --------------------
                          begin
                             commanded_mode <= MODE_PWRDOWN;
                             active_mode    <= MODE_PWRDOWN;
                             dbg_state      <= ST_DBG_WAIT_GOCLEAR;
                          end

                        CMD_SET_CLKDIV: // Set clock divisor -----------------------
                          begin
                             clkDiv    <= dwrite;
                             dbg_state <= ST_DBG_WAIT_GOCLEAR;
                          end

                        CMD_SET_CFG: // Set SWD Config ----------------------
                          begin
                             turnaround <= dwrite[1:0];
                             dataphase  <= dwrite[2];
                             dbg_state  <= ST_DBG_WAIT_GOCLEAR;
                          end

                        CMD_WAIT: // Wait for specified number of uS ---------------
                          begin
                             usecsdown <= dwrite;
                             dbg_state <= ST_DBG_WAIT_TIMEOUT;
                          end

                        CMD_CLR_ERR: // Clear error status -------------------------
                          begin
                             dbg_state <= ST_DBG_WAIT_GOCLEAR;
                          end

                        CMD_SET_RST_TMR: // Set reset timer ------------------------
                          begin
                             rst_timeout <= dwrite;
                             dbg_state   <= ST_DBG_WAIT_GOCLEAR;
                          end
                        
                        default: // Unknown, set an error --------------------------
                          begin
                             perr      <= 1;
                             dbg_state <= ST_DBG_WAIT_GOCLEAR;
                          end
                      endcase // case (command)
                   end // if (cdc_go==2'b11)

               ST_DBG_WAIT_GOCLEAR: // Waiting for go indication to clear =================================
                 if (cdc_go!=2'b11)
                   dbg_state <= ST_DBG_IDLE;
               
               ST_DBG_WAIT_INFERIOR_FINISH: // Waiting for inferior to complete its task ===================
                 case (active_mode)
                   MODE_SWD:
                     if (swd_idle)
                       begin
                          // This delberately goes to IDLE and not GO_CLEAR for streaming purposes
                          dbg_state <= ST_DBG_IDLE;
                          perr      <= swd_perr;
                       end
                   default:
                     begin
                        perr      <= 1'b1;
                        dbg_state <= ST_DBG_WAIT_GOCLEAR;
                     end
                 endcase

               ST_DBG_WAIT_INFERIOR_START: // Waiting for inferior to start its task =======================
                 case (active_mode)
                   MODE_SWD:
                     if (~swd_idle)
                       begin
                          if_go     <= 0;
                          dbg_state <= ST_DBG_WAIT_INFERIOR_FINISH;
                       end
                   default:
                     begin
                        if_go     <= 0;
                        perr      <= 1'b1;
                        dbg_state <= ST_DBG_WAIT_GOCLEAR;
                     end
                 endcase
               
               ST_DBG_WAIT_TIMEOUT: // Waiting for timeout to complete ====================================
                 if (!usecsdown)
                   dbg_state <= ST_DBG_WAIT_GOCLEAR;

               ST_DBG_WAIT_CLKCHANGE: // Waiting for clock state to change ================================
                 if (!cdivcount)
                   dbg_state <= ST_DBG_WAIT_GOCLEAR;
               
               ST_DBG_RESETTING: // We are in reset =======================================================
                 if (!usecsdown)
                   begin
                      usecsdown <= rst_timeout;
                      dbg_state <= ST_DBG_RESET_GUARD;
                   end

               ST_DBG_RESET_GUARD: // We have finished reset, but wait for chip to ack ====================
                 begin
                    if ((tgt_reset_state) || (!usecsdown))
                      dbg_state<=ST_DBG_WAIT_GOCLEAR;
                 end

               ST_DBG_ESTABLISH_MODE: // We want to set a specific mode ===================================
                 if (anedge)
                   begin
                      // Stay in sync with clock that is given to inferiors
                      if (fallingedge)
                        begin
                           // Our changes happen on the falling edge (i.e. pinw_swclk currently high)
                           if ((switch_step<50) || (switch_step>65)) pinw_swdo<=1'b1;
                           else
                             begin
                                pinw_swdo<=modechange[0];
                                modechange<={1'b0,modechange[15:1]};
                             end
                           if (switch_step>115)
                             pinw_swdo<=0;
                           if (switch_step==118)
                             dbg_state<=ST_DBG_WAIT_GOCLEAR;
                           switch_step<=switch_step+1;
                        end // if (fallingedge)
                   end // if (pinw_swclk)
             endcase // case (dbg_state)
             
          end // else: !if(rst)
     end // always @ (posedge clk, posedge rst)   
endmodule // dbgIF