module FinTS
  module Segment
    # HNSHK (Signaturkopf)
    # Section B.5.1
    class HNSHK < BaseSegment
      SECURITY_FUNC = 999
      SECURITY_BOUNDARY = 1  # SHM
      SECURITY_SUPPLIER_ROLE = 1  # ISS

      # security_ref_no is the "Sicherheitsreferenznummer": per the FinTS
      # Formals spec it must differ and increase with every signature within a
      # dialog (replay protection). Reusing a value makes strict banks reject
      # the message with "9340 Ungültige Signatur". The message number is used
      # as it is unique and increasing within a dialog.
      def initialize(segno, secref, blz, username, system_id, profile_version, security_function=SECURITY_FUNC, security_ref_no=1)
        data = [
          ['PIN', profile_version.to_s].join(':'),
          security_function,
          secref,
          SECURITY_BOUNDARY,
          SECURITY_SUPPLIER_ROLE,
          ['1', '', system_id.to_s].join(':'),
          security_ref_no,
          ['1', Time.now.strftime('%Y%m%d'), Time.now.strftime('%H%M%S')].join(':'),
          ['1', '999', '1'].join(':'),  # Negotiate hash algorithm
          ['6', '10', '16'].join(':'),  # RSA mode
          [country_code.to_s, blz, Helper.fints_escape(username), 'S', '0', '0'].join(':')
        ]
        super(segno, data)
      end

      protected

      def type
        'HNSHK'
      end
      
      def version
        4
      end
    end
  end
end
