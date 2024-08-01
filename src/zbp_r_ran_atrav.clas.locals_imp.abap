CLASS lhc_zr_ran_atrav DEFINITION INHERITING FROM cl_abap_behavior_handler.
  PRIVATE SECTION.
    CONSTANTS:
      BEGIN OF travel_status,
        open     TYPE c LENGTH 1 VALUE 'O', "Open
        accepted TYPE c LENGTH 1 VALUE 'A', "Accepted
        rejected TYPE c LENGTH 1 VALUE 'X', "Rejected
      END OF travel_status.
    METHODS:
      get_global_authorizations FOR GLOBAL AUTHORIZATION
        IMPORTING
        REQUEST requested_authorizations FOR zr_ran_atrav
        RESULT result,
      earlynumbering_create FOR NUMBERING
        IMPORTING entities FOR CREATE zr_ran_atrav,
      setstatustoopen FOR DETERMINE ON MODIFY
        IMPORTING keys FOR zr_ran_atrav~setstatustoopen,
      validatecustomer FOR VALIDATE ON SAVE
            IMPORTING keys FOR zr_ran_atrav~validatecustomer.

          METHODS validatedates FOR VALIDATE ON SAVE
            IMPORTING keys FOR zr_ran_atrav~validatedates.
ENDCLASS.

CLASS lhc_zr_ran_atrav IMPLEMENTATION.
  METHOD get_global_authorizations.
  ENDMETHOD.
  METHOD earlynumbering_create.
    DATA:
      entity           TYPE STRUCTURE FOR CREATE zr_ran_atrav,
      travel_id_max    TYPE /dmo/travel_id,
      " change to abap_false if you get the ABAP Runtime error 'BEHAVIOR_ILLEGAL_STATEMENT'
      use_number_range TYPE abap_bool VALUE abap_false.

    "Ensure Travel ID is not set yet (idempotent)- must be checked when BO is draft-enabled
    LOOP AT entities INTO entity WHERE TravelID IS NOT INITIAL.
      APPEND CORRESPONDING #( entity ) TO mapped-zr_ran_atrav.
    ENDLOOP.

    DATA(entities_wo_travelid) = entities.
    "Remove the entries with an existing Travel ID
    DELETE entities_wo_travelid WHERE TravelID IS NOT INITIAL.

    IF use_number_range = abap_true.
      "Get numbers
      TRY.
          cl_numberrange_runtime=>number_get(
            EXPORTING
              nr_range_nr       = '01'
              object            = '/DMO/TRV_M'
              quantity          = CONV #( lines( entities_wo_travelid ) )
            IMPORTING
              number            = DATA(number_range_key)
              returncode        = DATA(number_range_return_code)
              returned_quantity = DATA(number_range_returned_quantity)
          ).
        CATCH cx_number_ranges INTO DATA(lx_number_ranges).
          LOOP AT entities_wo_travelid INTO entity.
            APPEND VALUE #(  %cid      = entity-%cid
                             %key      = entity-%key
                             %is_draft = entity-%is_draft
                             %msg      = lx_number_ranges
                          ) TO reported-zr_ran_atrav.
            APPEND VALUE #(  %cid      = entity-%cid
                             %key      = entity-%key
                             %is_draft = entity-%is_draft
                          ) TO failed-zr_ran_atrav.
          ENDLOOP.
          EXIT.
      ENDTRY.

      "determine the first free travel ID from the number range
      travel_id_max = number_range_key - number_range_returned_quantity.
    ELSE.
      "determine the first free travel ID without number range
      "Get max travel ID from active table
      SELECT SINGLE FROM zr_ran_atrav FIELDS MAX( TravelID ) AS travelID INTO @travel_id_max.
      "Get max travel ID from draft table
      SELECT SINGLE FROM zr_ran_atrav FIELDS MAX( travelid ) INTO @DATA(max_travelid_draft).
      IF max_travelid_draft > travel_id_max.
        travel_id_max = max_travelid_draft.
      ENDIF.
    ENDIF.

    "Set Travel ID for new instances w/o ID
    LOOP AT entities_wo_travelid INTO entity.
      travel_id_max += 1.
      entity-TravelID = travel_id_max.

      APPEND VALUE #( %cid      = entity-%cid
                      %key      = entity-%key
                      %is_draft = entity-%is_draft
                    ) TO mapped-zr_ran_atrav.
    ENDLOOP.

  ENDMETHOD.

  METHOD setStatusToOpen.

    "Read travel instances of the transferred keys
    READ ENTITIES OF ZR_RAN_ATRAV IN LOCAL MODE
     ENTITY ZR_RAN_ATRAV
       FIELDS ( OverallStatus )
       WITH CORRESPONDING #( keys )
     RESULT DATA(travels)
     FAILED DATA(read_failed).

    "If overall travel status is already set, do nothing, i.e. remove such instances
    DELETE travels WHERE OverallStatus IS NOT INITIAL.
    CHECK travels IS NOT INITIAL.

    "else set overall travel status to open ('O')
    MODIFY ENTITIES OF ZR_RAN_ATRAV IN LOCAL MODE
      ENTITY ZR_RAN_ATRAV
        UPDATE SET FIELDS
        WITH VALUE #( FOR travel IN travels ( %tky    = travel-%tky
                                              OverallStatus = travel_status-open ) )
    REPORTED DATA(update_reported).

    "Set the changing parameter
    reported = CORRESPONDING #( DEEP update_reported ).




    "Read travel instances of the transferred keys
    READ ENTITIES OF ZR_RAN_ATRAV IN LOCAL MODE
     ENTITY ZR_RAN_ATRAV
       FIELDS ( Description )
       WITH CORRESPONDING #( keys )
     RESULT DATA(travels2)
     FAILED DATA(read_failed2).

    "If overall travel status is already set, do nothing, i.e. remove such instances
    DELETE travels2 WHERE Description IS NOT INITIAL.
    CHECK travels2 IS NOT INITIAL.

    "else set overall travel status to open ('O')
    MODIFY ENTITIES OF ZR_RAN_ATRAV IN LOCAL MODE
      ENTITY ZR_RAN_ATRAV
        UPDATE SET FIELDS
        WITH VALUE #( FOR travel IN travels2 ( %tky    = travel-%tky
                                              Description = 'nová položka' ) )
    REPORTED DATA(update_reported2).

    "Set the changing parameter
    reported = CORRESPONDING #( DEEP update_reported ).


  ENDMETHOD.

  METHOD validateCustomer.
      "read relevant travel instance data
      READ ENTITIES OF ZR_RAN_ATRAV IN LOCAL MODE
      ENTITY ZR_RAN_ATRAV
       FIELDS ( CustomerID )
       WITH CORRESPONDING #( keys )
      RESULT DATA(travels).

      DATA customers TYPE SORTED TABLE OF /dmo/customer WITH UNIQUE KEY customer_id.

      "optimization of DB select: extract distinct non-initial customer IDs
      customers = CORRESPONDING #( travels DISCARDING DUPLICATES MAPPING customer_id = customerID EXCEPT * ).
      DELETE customers WHERE customer_id IS INITIAL.
      IF customers IS NOT INITIAL.

        "check if customer ID exists
        SELECT FROM /dmo/customer FIELDS customer_id
                                  FOR ALL ENTRIES IN @customers
                                  WHERE customer_id = @customers-customer_id
          INTO TABLE @DATA(valid_customers).
      ENDIF.

      "raise msg for non existing and initial customer id
      LOOP AT travels INTO DATA(travel).

        APPEND VALUE #(  %tky                 = travel-%tky
                         %state_area          = 'VALIDATE_CUSTOMER'
                       ) TO reported-ZR_RAN_ATRAV.

        IF travel-CustomerID IS  INITIAL.
          APPEND VALUE #( %tky = travel-%tky ) TO failed-ZR_RAN_ATRAV.

          APPEND VALUE #( %tky                = travel-%tky
                          %state_area         = 'VALIDATE_CUSTOMER'
                          %msg                = NEW /dmo/cm_flight_messages(
                                                                  textid   = /dmo/cm_flight_messages=>enter_customer_id
                                                                  severity = if_abap_behv_message=>severity-error )
                          %element-CustomerID = if_abap_behv=>mk-on
                        ) TO reported-ZR_RAN_ATRAV.

        ELSEIF travel-CustomerID IS NOT INITIAL AND NOT line_exists( valid_customers[ customer_id = travel-CustomerID ] ).
          APPEND VALUE #(  %tky = travel-%tky ) TO failed-ZR_RAN_ATRAV.

          APPEND VALUE #(  %tky                = travel-%tky
                           %state_area         = 'VALIDATE_CUSTOMER'
                           %msg                = NEW /dmo/cm_flight_messages(
                                                                  customer_id = travel-customerid
                                                                  textid      = /dmo/cm_flight_messages=>customer_unkown
                                                                  severity    = if_abap_behv_message=>severity-error )
                           %element-CustomerID = if_abap_behv=>mk-on
                        ) TO reported-ZR_RAN_ATRAV.
        ENDIF.

      ENDLOOP.
  ENDMETHOD.

  METHOD validateDates.
    READ ENTITIES OF ZR_RAN_ATRAV IN LOCAL MODE
      ENTITY ZR_RAN_ATRAV
        FIELDS (  BeginDate EndDate TravelID )
        WITH CORRESPONDING #( keys )
      RESULT DATA(travels).

    LOOP AT travels INTO DATA(travel).

      APPEND VALUE #(  %tky               = travel-%tky
                       %state_area        = 'VALIDATE_DATES' ) TO reported-ZR_RAN_ATRAV.

      IF travel-BeginDate IS INITIAL.
        APPEND VALUE #( %tky = travel-%tky ) TO failed-ZR_RAN_ATRAV.

        APPEND VALUE #( %tky               = travel-%tky
                        %state_area        = 'VALIDATE_DATES'
                         %msg              = NEW /dmo/cm_flight_messages(
                                                                textid   = /dmo/cm_flight_messages=>enter_begin_date
                                                                severity = if_abap_behv_message=>severity-error )
                      %element-BeginDate = if_abap_behv=>mk-on ) TO reported-ZR_RAN_ATRAV.
      ENDIF.
      IF travel-BeginDate < cl_abap_context_info=>get_system_date( ) AND travel-BeginDate IS NOT INITIAL.
        APPEND VALUE #( %tky               = travel-%tky ) TO failed-ZR_RAN_ATRAV.

        APPEND VALUE #( %tky               = travel-%tky
                        %state_area        = 'VALIDATE_DATES'
                         %msg              = NEW /dmo/cm_flight_messages(
                                                                begin_date = travel-BeginDate
                                                                textid     = /dmo/cm_flight_messages=>begin_date_on_or_bef_sysdate
                                                                severity   = if_abap_behv_message=>severity-error )
                        %element-BeginDate = if_abap_behv=>mk-on ) TO reported-ZR_RAN_ATRAV.
      ENDIF.
      IF travel-EndDate IS INITIAL.
        APPEND VALUE #( %tky = travel-%tky ) TO failed-ZR_RAN_ATRAV.

        APPEND VALUE #( %tky               = travel-%tky
                        %state_area        = 'VALIDATE_DATES'
                         %msg                = NEW /dmo/cm_flight_messages(
                                                                textid   = /dmo/cm_flight_messages=>enter_end_date
                                                               severity = if_abap_behv_message=>severity-error )
                        %element-EndDate   = if_abap_behv=>mk-on ) TO reported-ZR_RAN_ATRAV.
      ENDIF.
      IF travel-EndDate < travel-BeginDate AND travel-BeginDate IS NOT INITIAL
                                           AND travel-EndDate IS NOT INITIAL.
        APPEND VALUE #( %tky = travel-%tky ) TO failed-ZR_RAN_ATRAV.

        APPEND VALUE #( %tky               = travel-%tky
                        %state_area        = 'VALIDATE_DATES'
                        %msg               = NEW /dmo/cm_flight_messages(
                                                                textid     = /dmo/cm_flight_messages=>begin_date_bef_end_date
                                                                begin_date = travel-BeginDate
                                                                end_date   = travel-EndDate
                                                                severity   = if_abap_behv_message=>severity-error )
                        %element-BeginDate = if_abap_behv=>mk-on
                        %element-EndDate   = if_abap_behv=>mk-on ) TO reported-ZR_RAN_ATRAV.
      ENDIF.
    ENDLOOP.
  ENDMETHOD.

ENDCLASS.
