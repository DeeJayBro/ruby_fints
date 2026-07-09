ruby_fints
==========

This is a pure-Ruby implementation of FinTS (formerly known as HBCI), a
online-banking protocol commonly supported by German banks.

Limitations
-----------

* Only FinTS 3.0 is supported
* Only PIN/TAN authentication is supported, no signature cards
* Only a number of reading operations are currently supported
* Supports Ruby 2.2+

Banks tested:

* Sparkasse
* ING DiBa
* GLS Bank
* comdirect

Usage
-----

```ruby
require 'ruby_fints'
require 'pp'

FinTS::Client.logger.level = Logger::DEBUG
f = FinTS::PinTanClient.new(
    '123456789',  # Your bank's BLZ
    'myusername',
    'mypin',
    'https://mybank.com/...',  # endpoint, e.g.: https://hbci-pintan.gad.de/cgi-bin/hbciservlet
    # Since PSD2 most banks require a product registration number issued by the
    # Deutsche Kreditwirtschaft (https://www.hbci-zka.de/register/prod_register.htm).
    # Unregistered products are rejected with
    # "9078 - Dialog abgebrochen - Banking-Programm ist nicht registriert".
    product_name: 'YOUR_REGISTRATION_NUMBER',
    product_version: '1.0'
)

accounts = f.get_sepa_accounts
pp accounts
# [{iban: 'DE12345678901234567890', bic: 'ABCDEFGH1DEF', accountnumber: '123456790', subaccount: '', blz: '123456789'}]

balance = f.get_balance(accounts[0])
pp balance
# {:amount=>1234.56,
#  :currency=>"EUR",
#  :date=>#<Date: 2018-08-21 ((2458352j,0s,0n),+0s,2299161j)>}

# Transactions are requested in the CAMT format (HKCAZ) and parsed from the
# bank's ISO 20022 camt.05x XML into hashes. Amounts are signed (negative means
# money left the account). Requires the bank to advertise CAMT support in its
# bank parameter data (HICAZS); otherwise a SegmentNotFoundError is raised.
#
# The commonly used values are lifted to convenient top-level keys, but CAMT is
# much richer than those, so the complete, loss-free entry is always kept under
# :raw (a nested hash mirroring the XML). Nothing the bank sent is discarded.
#
# get_transactions is an alias for get_statement (they are identical).
transactions = f.get_transactions(accounts[0], Date.new(2017, 4, 3), Date.new(2017, 4, 4))
pp transactions

# [{:amount=>96.38,
#   :currency=>"EUR",
#   :status=>"BOOK",
#   :booked=>true,
#   :booking_date=>#<Date: 2017-04-04 …>,
#   :value_date=>#<Date: 2017-04-04 …>,
#   :name=>"Stripe Payments UK Ltd",
#   :iban=>"DK6689000000010241",
#   :bic=>"PBNKDEFFXXX",
#   :purpose=>"STRIPEX4J1J3",
#   :end_to_end_id=>"NOTPROVIDED",
#   :mandate_id=>nil,
#   :creditor_id=>nil,
#   :reference=>"NONREF",
#   :additional_info=>"SEPA GUTSCHRIFT",
#   :transaction_code=>"166",
#   # everything else CAMT carried (amount details, charges, FX, ultimate
#   # parties, structured remittance, …) is preserved here:
#   :raw=>{"Amt"=>{"@Ccy"=>"EUR", "#text"=>"96.38"}, "CdtDbtInd"=>"CRDT", …}}]

# for retrieving the securities holdings (Depotaufstellung) of an account
holdings = f.get_holdings(accounts[0])
pp holdings
# [{:ISIN=>"LU0635178014",
#   :name=>"COMS.-MSCI EM.M.T.U.ETF I",
#   :market_value=>38.82,
#   :value_symbol=>"EUR",
#   :valuation_date=>#<Date: 2017-04-28 ((2457872j,0s,0n),+0s,2299161j)>,
#   :pieces=>16.8211,
#   :total_value=>970.17}]
```

PSD2 / strong customer authentication
-------------------------------------

Since PSD2 most banks enforce strong customer authentication (SCA) and reject
clients that do not participate with
`9075 - Banking-Programm nicht PSD2-fähig`. This library announces SCA
capability by sending an `HKTAN` segment (two-step TAN, "Prozessvariante 2")
during dialog initialisation, and attaches an `HKTAN` to each read order
(balance, statement, holdings) so the order itself is authorised — without it
banks reject the order with
`9370 - Anzahl Signaturen für diesen Auftrag unzureichend`. For decoupled
methods the order result is delivered once you approve the request in your app.

Two SCA styles are supported:

* **Decoupled** (approval in your banking app, e.g. pushTAN — no TAN is typed).
  The client polls the bank until you approve the request. This is used
  automatically when the challenge carries no image.
* **Image-based** (photoTAN) as a fallback: the challenge carries an image; the
  client hands it to your `tan_handler`, which shows it and returns the TAN the
  user typed after scanning.

```ruby
f = FinTS::PinTanClient.new(
    '123456789', 'myusername', 'mypin', 'https://mybank.com/...',
    product_name:    'YOUR_REGISTRATION_NUMBER',
    tan_mechanism:   '942',   # optional: security function to use for signing
                              #           (see the dialog's #tan_methods after sync)
    tan_medium:      nil,     # optional: TAN medium name, if your method needs one
    poll_interval:   5,       # decoupled: seconds between "approved yet?" polls
    max_poll_attempts: 60,    # decoupled: give up after this many polls
    # invoked for image/challenge methods (photoTAN); return the TAN string
    tan_handler: ->(challenge) {
      # challenge => { text: "Siehe Grafik", image: "<PNG bytes>", order_ref: "..." }
      IO.binwrite('phototan.png', challenge[:image]) if challenge[:image]
      print "#{challenge[:text]} (see phototan.png) — enter TAN: "
      $stdin.gets.strip
    }
)

balance = f.get_balance(accounts[0]) # blocks until you approve/enter the TAN
```

The bank advertises the available TAN methods in its `HITANS` segment; the
allowed security functions come from `HIRMS 3920`. Read-only calls covered by
the PSD2 90-day exemption are answered without a challenge and return
immediately.

Credits
-------

This is a close port of [python-fints](https://github.com/raphaelm/python-fints) library by Raphael Michel
which in turn is a port of the [fints-hbci-php](https://github.com/mschindler83/fints-hbci-php)
implementation that was released by Markus Schindler under the MIT license.

Thanks for your work!
