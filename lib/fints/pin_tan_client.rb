module FinTS
  class PinTanClient < Client
    def initialize(blz, username, pin, server, product_name: FinTS::GEM_NAME, product_version: FinTS::VERSION,
                   tan_mechanism: nil, tan_medium: nil, poll_interval: 5, max_poll_attempts: 60, tan_handler: nil, &block)
      @blz = blz
      @username = username
      @pin = pin
      @connection = HTTPSConnection.new(server)
      @system_id = 0
      @product_name = product_name
      @product_version = product_version
      @tan_mechanism = tan_mechanism
      @tan_medium = tan_medium
      @poll_interval = poll_interval
      @max_poll_attempts = max_poll_attempts
      # Callback invoked when the bank challenges with a TAN (e.g. photoTAN): it
      # receives {text:, image:, order_ref:} and returns the TAN string. A block
      # passed to .new is used as the handler too.
      @tan_handler = tan_handler || block
      @bpd = nil # bank/user parameter data cached after the first synchronisation
      super()
    end

    # The customer system ID and bank parameter data have been synchronised, so
    # later dialogs can reuse them instead of registering a new customer system.
    def dialog_established?
      @system_id != 0 && !@bpd.nil?
    end

    def remember_dialog(dialog)
      @system_id = dialog.system_id
      @bpd = dialog.parameters
    end

    def holdings_available?
      !!(@bpd && @bpd[:holdings_supported])
    end

    def camt_storage_days
      @bpd && @bpd[:camt_storage_days]
    end

    protected

    def new_dialog
      dialog = Dialog.new(@blz, @username, @pin, @system_id, @connection,
                          product_name: @product_name, product_version: @product_version,
                          tan_mechanism: @tan_mechanism, tan_medium: @tan_medium,
                          poll_interval: @poll_interval, max_poll_attempts: @max_poll_attempts,
                          tan_handler: @tan_handler)
      dialog.restore(@bpd)
      dialog
    end

    def new_message(dialog, segments)
      Message.new(@blz, @username, @pin, dialog.system_id, dialog.dialog_id, dialog.msg_no, segments, dialog.tan_mechs)
    end
  end
end
