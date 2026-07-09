module FinTS
  module Segment
    # HNSHA (Signaturabschluss)
    # Section B.5.2
    class HNSHA < BaseSegment
      SECURITY_FUNC = 999
      SECURITY_BOUNDARY = 1  # SHM
      SECURITY_SUPPLIER_ROLE = 1  # ISS
      PINTAN_VERSION = 1  # 1-step

      # The user-defined signature (DE3) carries the PIN, plus the TAN as a
      # second sub-element (PIN:TAN) when a two-step TAN is being submitted.
      def initialize(segno, secref, pin, tan: nil)
        signature = Helper.fints_escape(pin)
        signature = "#{signature}:#{Helper.fints_escape(tan)}" unless tan.nil? || tan.to_s.empty?
        data = [secref, '', signature]
        super(segno, data)
      end

      protected

      def type
        'HNSHA'
      end
      
      def version
        2
      end
    end
  end
end
