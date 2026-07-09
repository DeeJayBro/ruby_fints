module FinTS
  module Segment
    # HKTAN (Zwei-Schritt-TAN-Einreichung)
    # Refs: FinTS_3.0_Security_Sicherheitsverfahren_PINTAN, "Prozessvariante 2".
    #
    # Carries the strong-customer-authentication (PSD2 / SCA) request. Two of
    # the TAN processes are relevant for the decoupled ("app approval") flow:
    #
    #   '4' - initial submission: ask the bank to start SCA for +segment_id+
    #         (e.g. 'HKIDN' when authenticating the dialog itself). The bank
    #         answers with a HITAN carrying an order reference.
    #   '2' - TAN submission: submit the TAN the user entered for a challenge
    #         (e.g. photoTAN), referencing the order via +order_ref+. The TAN
    #         itself travels in HNSHA, not here.
    #   'S' - status request: poll a pending decoupled authorisation using the
    #         order reference from the HITAN response, until the user approves
    #         it in their banking app.
    class HKTAN < BaseSegment
      def initialize(segno, version, tan_process, segment_id: nil, order_ref: nil, tan_medium: nil)
        @version = version
        @tan_process = tan_process.to_s
        data =
          case @tan_process
          when '4'
            build_initial(segment_id, tan_medium)
          when '2', 'S'
            build_with_reference(order_ref)
          else
            raise ArgumentError, "Unsupported HKTAN TAN process #{tan_process.inspect}"
          end
        super(segno, data)
      end

      protected

      def type
        'HKTAN'
      end

      def version
        @version
      end

      private

      # DE1 TAN-Prozess, DE2 Segmentkennung, ... DE11 TAN-Medium-Bezeichnung.
      # Trailing empty data elements are only emitted when a later one (the TAN
      # medium) has to be present.
      def build_initial(segment_id, tan_medium)
        data = ['4', segment_id.to_s]
        unless tan_medium.nil? || tan_medium.to_s.empty?
          # pad DE3..DE10 (Kontoverbindung, Hashwert, Auftragsreferenz, weitere
          # TAN folgt, Abbruch, SMS-Konto, Challenge-Klasse, Parameter) as empty
          data.concat(Array.new(8, ''))
          data << Helper.fints_escape(tan_medium.to_s)
        end
        data
      end

      # DE1 TAN-Prozess ('2' TAN submission or 'S' decoupled status), DE2..DE4
      # empty, DE5 Auftragsreferenz, DE6 "Weitere TAN folgt"='N' (this is the
      # last/only security release for the order; required per FinTS PIN/TAN
      # §B.4.2.2.1 Schritt 2a).
      def build_with_reference(order_ref)
        if order_ref.nil? || order_ref.to_s.empty?
          raise ArgumentError, "HKTAN process #{@tan_process} requires an order reference"
        end
        [@tan_process, '', '', '', Helper.fints_escape(order_ref.to_s), 'N']
      end
    end
  end
end
