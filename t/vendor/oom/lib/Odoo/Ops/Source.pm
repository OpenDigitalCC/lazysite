package Odoo::Ops::Source;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Basename qw(dirname);
use File::Spec;
use JSON::PP ();
use Odoo::JSON ();
use Math::BigFloat;
use Template;
use Text::CSV_XS;
use YAML::PP;

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Credential;
use Odoo::Ops::Match;
use Odoo::Ops::Source::Lazysite;

=head1 NAME

Odoo::Ops::Source - read an input and map it to logical fields

=head1 SYNOPSIS

    my $src  = Odoo::Ops::Source->load('sources/expo-2026/mapping.yaml');
    for my $row (@{ $src->rows }) {
        $row->{key};       # stable source key
        $row->{held};      # e.g. 'flag:self_test' - never imported
        $row->{error};     # a mapping problem, by name
        $row->{values};    # { email => ..., tags => [...], ... } logical
    }

=head1 DESCRIPTION

A mapping file says where the rows are, how each is keyed, and how
logical fields are built from it. Paths are relative to the mapping
file.

    source: expo-2026                  # a name for reports and plans
    target: lead                       # logical model in the profile
    reader:
      kind: json-dir                   # json-dir | jsonl | csv | dbi | lazysite-table
      path: ../../opendigital/leads    # a directory (json-dir) or file
      record: data                     # dotted path to the record (json)
      key: source.key                  # dotted path (json) / column (csv)
      flags: flags                     # dotted path to a list of flags
    hold_flags: [self_test]            # rows carrying these are held
    fields:
      email:
        from: email                    # dotted path within the record
        transform: [trim, lower]
      tags:
        from: company
        transform: [split:;, trim]
        map: { "Open Digital": "Open Digital" }   # rename values; unmapped kept
        add: [Expo 2026]               # constants appended (lists)
      title:
        template: "Expo 2026 - [% name %]"         # Template Toolkit, over the record
      type: { const: lead }
      notes:
        template: |
          [% interest %]
        on_match: append               # used by import: fill|add|append|overwrite|ignore

Transforms, applied in order to a scalar or to each element of a
list: C<trim>, C<lower>, C<upper>, C<collapse> (runs of whitespace to
one space), C<split:SEP> (scalar to list), C<digits> (keep 0-9 and a
leading +), C<blank_undef> (empty string to undef), and, new in 0.08:

=over 4

=item C<title_case>

Each word's first letter upper, the rest lower, on a collapsed string.

=item C<strip_html>

Tags removed (block tags such as C<br> and C<p> become a space),
C<&amp; &lt; &gt; &quot; &nbsp;> decoded, whitespace collapsed.

=item C<round:N>

A number to N places (0-12), half away from zero, string in and string
out ("2.675" with C<round:2> is "2.68"); a non-numeric value is left
as it is.

=item C<regex:PATTERN:REPLACEMENT>

A global substitution. C<\:> in the pattern or the replacement is a
literal colon; C<$1> or C<\1> in the replacement is a capture. An
invalid or empty pattern refuses the mapping at load, naming the field.

=item C<vat:CC>

Spaces removed, upper-cased, the country prefix added when absent. A
number that cannot be a VAT number becomes undef and the row records
C<invalid:vat> (and is held, see C<require>). GB numbers must be
C<GB> and nine digits, with the modulus-97 check of the legacy
C<validate_vat>; other countries are checked for shape only (prefix
and 2-12 letters or digits).

=item C<phone:CC>

The first number found by L<Odoo::Ops::Match/norm_phones> for the
country calling code CC (C<phone:44>): digits with a leading C<+>, a
leading single 0 read as C<+CC>. Nothing usable (fewer than 7 digits)
gives undef.

=item C<json>

Text to a structure (JSON decoded), for a template that builds a list of
records; an empty value stays undef and text that is not JSON makes the
row an error naming the field.

=back

A template is
rendered with the whole record as its variables (plus C<source_key>, the row's source key - Template Toolkit hides names starting with an underscore), and
its output trimmed.

=head2 The dbi reader

    reader:
      kind: dbi
      credential: legacy-ledger        # a file of dsn, user, password lines
      sql: "SELECT * FROM CUS_TBL WHERE CUS_CODE > 0 ORDER BY CUS_CODE"
      key: CUS_CODE                    # the column that keys a row (else row<n>)

The result set of one SELECT is the rows; each is a record keyed by the
column names the driver gives, and the mapping names them as they are.
C<credential> is a path (relative to the mapping) or a bare name read as
C<NAME.dsn> beside the mapping or under C<$OOM_CREDENTIALS_DIR>; the
file is read by L<Odoo::Ops::Credential/dsn> (mode 0600) and a C<dsn>,
C<user> or C<password> written in the mapping is refused. DBI is loaded
only when such a reader runs (C<libdbi-perl> and the database's driver
are Recommends of the package). Tests, and a program that holds its own
connection, pass the handle: C<< Odoo::Ops::Source->load($path, dbh =>
$dbh) >>, and no credential is read. Only a SELECT is accepted.

=head2 The lazysite-table reader

    reader:
      kind: lazysite-table
      api: https://site.example/cgi-bin/lazysite-manager-api.pl
      credential: recon-portal         # a Credential of kind lazysite_token
      table: recon_so                  # the rows of this table are the records
      key: so                          # the column that keys a row (else row<n>)
      where: { status: ready }         # optional, client-side equality (a list is any-of)
      also: { questions: recon_question, answers: recon_answer }

A lazysite site's data tables are read through its manager API,
C<POST api?action=data-export&table=NAME>, by L<Odoo::Ops::Source::Lazysite>
(the one place that speaks the protocol; nothing is written back). The
token is a JSON file C<{ "partner", "token", "expires" }>, mode 0600,
read by L<Odoo::Ops::Credential/lazysite_token>: C<credential> is a path
or a bare name read as C<NAME.json> beside the mapping or under
C<$OOM_CREDENTIALS_DIR>. A C<token>, C<partner> or C<password> written in
the mapping is refused at load, and an expired token is a refusal
naming the file (rotation is not done here). An C<ok: false> answer is
an L<Odoo::Error> of kind C<fault>, category C<lazysite>, with the site's
own words, and is not retried; a transport failure is retried on a short
ladder and then dies as kind C<transport>. C<ssl_ca_file>, C<ssl_verify>
and C<timeout> may be given in the reader, as the Odoo connection takes
them. Tests pass the HTTP object: C<< Odoo::Ops::Source->load($path, http
=> $fake) >>.

=head3 A joined read

C<also> names further tables; they are fetched with the first and every
template and C<hold_when> rule sees them as C<tables.NAME>, a list of
hashes, with the reader's own table row as the record. There is no join
language: Template Toolkit loops and filters. This builds the input of
C<stock.dispatch> (one row per sale order: C<order>, C<date>, C<lines>
each with C<product>, C<qty> and C<lots>, and C<note>) from the four
tables of the recall portal for each order whose C<recon_so> row is
ready:

    source: recon-portal
    target: stock.dispatch
    reader:
      kind: lazysite-table
      api: https://site.example/manager-api
      credential: portal
      table: recon_so
      key: so
      where: { status: ready }
      also: { questions: recon_question, answers: recon_answer, picks: recon_pick }
    fields:
      order: { from: so }
      date:                            # the pick of the order's delivery
        template: |
          [% done = 0 %]
          [% FOREACH q IN tables.questions.sort('qid') %][% NEXT UNLESS q.sale_order == so %]
          [% FOREACH p IN tables.picks %][% IF NOT done AND p.delivery == q.delivery AND p.dispatch_date %][% p.dispatch_date %][% done = 1 %][% END %][% END %]
          [% END %]
        require: [present, date]
      lines:                           # answers "L1=70;L2=50"; a bare "L3" is the whole quantity
        template: |
          [% n = 0 %][
          [% FOREACH q IN tables.questions.sort('qid') %][% NEXT UNLESS q.sale_order == so AND q.kind == 'undispatched' %]
          [% FOREACH a IN tables.answers %][% NEXT UNLESS a.qid == q.qid %][% IF n %],[% END %][% n = n + 1 %]
          {"product":"[% q.product_code %]","qty":[% q.qty %],"lots":{[% m = 0 %][% FOREACH pair IN a.answer.split(';') %][% kv = pair.split('=') %][% IF m %],[% END %][% m = m + 1 %]"[% kv.0.trim %]":[% kv.1.defined ? kv.1.trim : q.qty %][% END %]}}
          [% END %][% END %]
          ]
        transform: [json]
        require: present
      note: { template: "Loading sheet [% so %], answered on the recall portal" }
      check:                           # a question unanswered or UNKNOWN holds the order
        template: |
          [% bad = [] %][% FOREACH q IN tables.questions.sort('qid') %][% NEXT UNLESS q.sale_order == so AND q.kind == 'undispatched' %]
          [% got = '' %][% FOREACH a IN tables.answers %][% IF a.qid == q.qid %][% got = a.answer %][% END %][% END %]
          [% bad.push(q.qid) IF got == '' OR got.upper == 'UNKNOWN' %]
          [% END %][% bad.size ? 'unanswered ' _ bad.join(',') : 'ok' %]
        require: "regex:^ok$"

For order S00123 (two undispatched questions answered C<L1=70;L2=50> and
C<L3>, a pick dated 2026-09-07) the row's values are C<< order =>
'S00123', date => '2026-09-07', lines => [ {product => 'C40', qty =>
120, lots => {L1 => 70, L2 => 50}}, {product => 'P30', qty => 10, lots
=> {L3 => 10}} ] >> and the note; an order with no answers, an UNKNOWN
answer or no pick date comes back held, every reason listed. C<check>
is an extra value the consumer ignores. The mapping is the one run in
C<t/27-source-lazysite.t>; the dates are ISO in the pick table (a site
that keeps C<dd/mm/yyyy> adds a C<regex:> transform).

=head2 Holds

Two ways to hold rows, beside source flags:

    hold_when:                         # rules, over the raw record (TT)
      - if: "company == 'Cloudient'"
        reason: Cloudient-only enquiry - belongs in the Cloudient CRM
    overrides: overrides.yaml          # a person's per-record decisions

The overrides file is keyed by source key; each entry may C<set> raw
record fields before mapping (C<~> blanks one) and/or C<hold> the row
with a reason:

    "0008": { set: { note: ~ }, why: "note is bookkeeping only" }
    "2b2a2e041a6734b8": { hold: spam, why: "SEO solicitation" }

An override for a key the source does not have is an error (a stale
decision must not linger silently). C<held> is C<flag:NAME>,
C<rule:REASON> or C<override:WHAT - WHY>.

A third, per field: C<require> holds the row, by name, when the value
after the transforms does not satisfy it:

    fields:
      email: { from: EMAIL, transform: [trim, lower], require: email }
      vat:   { from: VAT_NO, transform: ["vat:GB"], require: present }
      zip:   { from: POSTCODE, require: "regex:^[A-Z]{1,2}[0-9][A-Z0-9]? ?[0-9][A-Z]{2}$" }

C<require> is C<present>, C<email> (the shape C<Match::norm_email>
accepts), C<number>, C<date> (YYYY-MM-DD, a real day) or C<regex:PATTERN>,
or a list of them. An empty value (undef, blank, an empty list) passes
every check except C<present>, so C<require: email> alone means "optional,
but valid when given" and C<require: [present, email]> means "mandatory
and valid"; a list is checked check by check and each failure is named.
(Before the list form an empty value failed every check; a mapping that
relied on that adds C<present>.) A failing row is held as
C<rule:FIELD REQUIRE failed>; every
failure is listed in the reason, C<; > between them, and an
C<invalid:vat> mark from C<vat:> is listed as C<FIELD invalid:vat>. The
row also carries C<invalid>, the list of marks. A row already held by a
flag, an override or a C<hold_when> rule keeps that hold. Such rows reach
C<core.import> and C<crm.import> as C<held-rule>.

Every row comes back - a row that cannot be mapped carries C<error>,
a held row carries C<held>; nothing is dropped.

=cut

my %TRANSFORM = (
    trim        => sub ($v) { defined $v ? $v =~ s/^\s+|\s+\z//gr : $v },
    lower       => sub ($v) { defined $v ? lc $v : $v },
    upper       => sub ($v) { defined $v ? uc $v : $v },
    collapse    => sub ($v) { defined $v ? $v =~ s/\s+/ /gr : $v },
    digits      => sub ($v) { defined $v ? ( ( $v =~ /^\s*\+/ ? '+' : '' ) . ( $v =~ s/\D//gr ) ) : $v },
    blank_undef => sub ($v) { defined $v && $v =~ /\S/ ? $v : undef },
    # text to a structure, for a template that builds a list of records;
    # empty stays undef, anything else that is not JSON is a row error
    json        => sub ($v) {
        return $v if !defined $v || ref $v;
        return undef if $v !~ /\S/;
        my $d = eval { Odoo::JSON->new( utf8 => 0 )->decode($v) };
        die 'transform json: not valid JSON (' . ( $@ =~ s/\s+at \S+ line \d+.*//sr ) . ")\n" if $@;
        return $d;
    },
    title_case  => sub ($v) {
        return $v if !defined $v;
        return join ' ', map { ucfirst lc } grep { length } split /\s+/, $v;
    },
    strip_html  => sub ($v) {
        return $v if !defined $v;
        # block-level tags separate words; inline ones vanish
        $v =~ s{</?(?:br|p|div|li|ul|ol|tr|td|th|table|h[1-6])\b[^>]*>}{ }gi;
        $v =~ s/<[^>]*>//g;
        my %ent = ( lt => '<', gt => '>', quot => '"', nbsp => ' ' );
        $v =~ s/&(lt|gt|quot|nbsp);/$ent{$1}/g;
        $v =~ s/&amp;/&/g;    # last, so &amp;lt; reads as the text &lt;
        return $v =~ s/\s+/ /gr =~ s/^ | \z//gr;
    },
);

# Transforms with an argument after the first colon. Each factory gets
# the argument and the field's name (for a refusal) and returns the
# function ($value, \@marks) plus a flag: true when it takes the whole
# value (split makes a list from a scalar) instead of each list element.
my %TRANSFORM_ARG = (
    split => sub ($arg, $lf) {
        my $sep = $arg;
        return ( sub ($v, $m) { defined $v && !ref $v ? [ split /\Q$sep\E/, $v ] : $v }, 1 );
    },
    round => sub ($arg, $lf) {
        Odoo::Error->throw( kind => 'usage', message => "mapping field '$lf': transform 'round:$arg' needs a number of places 0-12", fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' )
            if $arg !~ /^\d{1,2}\z/ || $arg > 12;
        return sub ($v, $m) { _round( $v, $arg ) };
    },
    regex => sub ($arg, $lf) {
        my ( $pat, $repl ) = split /(?<!\\):/, $arg, 2;
        for ( $pat, $repl ) { $_ = '' if !defined; s/\\:/:/g }
        my $re = eval { qr/$pat/ };
        Odoo::Error->throw( kind => 'usage', message => "mapping field '$lf': transform 'regex:$arg' has an invalid pattern: " . ( $@ =~ s/ at \S+ line \d+.*//sr ), fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' )
            if !$re || $pat eq '';
        return sub ($v, $m) {
            return $v if !defined $v;
            return $v =~ s{$re}{ _expand( $repl, [ @{^CAPTURE} ] ) }ger;
        };
    },
    vat => sub ($arg, $lf) {
        Odoo::Error->throw( kind => 'usage', message => "mapping field '$lf': transform 'vat:$arg' needs a two-letter country code", fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' )
            if $arg !~ /^[A-Za-z]{2}\z/;
        my $cc = uc $arg;
        return sub ($v, $m) {
            my $out = _vat( $v, $cc );
            push @$m, 'invalid:vat' if defined $v && $v =~ /\S/ && !defined $out;
            return $out;
        };
    },
    phone => sub ($arg, $lf) {
        Odoo::Error->throw( kind => 'usage', message => "mapping field '$lf': transform 'phone:$arg' needs a country calling code (digits, e.g. phone:44)", fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' )
            if $arg !~ /^\d{1,3}\z/;
        my $match = Odoo::Ops::Match->new( keys => ['phone'], phone_cc => $arg );
        return sub ($v, $m) {
            return $v if !defined $v;
            my ($first) = $match->norm_phones($v);
            return $first;
        };
    },
);

# A number rounded half away from zero to N places, as text; anything
# that is not a plain decimal is returned as it came.
sub _round ($v, $places) {
    return $v if !defined $v || ref $v || $v !~ /^\s*([-+]?)(\d+(?:\.\d*)?|\.\d+)\s*\z/;
    my ( $sign, $num ) = ( $1, $2 );
    my $scaled = Math::BigFloat->new($num)->bmul( Math::BigFloat->new(10)->bpow($places) )->badd('0.5')->bfloor;
    my $digits = $scaled->bstr;
    $digits = '0' x ( $places + 1 - length $digits ) . $digits if length $digits <= $places;
    my $out = $places ? substr( $digits, 0, -$places ) . '.' . substr( $digits, -$places ) : $digits;
    return ( $sign eq '-' && $out =~ /[1-9]/ ? '-' : '' ) . $out;
}

# $1..$9 and \1..\9 in a regex replacement
sub _expand ($repl, $cap) {
    return $repl =~ s/(?:\$|\\)(\d)/$cap->[ $1 - 1 ] \/\/ ''/ger;
}

# A VAT number with its country prefix, or undef when it cannot be one.
# Only GB is checked beyond shape: nine digits and the modulus-97 rule
# of the legacy DataTransforms::validate_vat.
sub _vat ($v, $cc) {
    return undef if !defined $v || $v !~ /\S/;
    my $n = uc( $v =~ s/\s+//gr );
    $n = "$cc$n" if $n !~ /^\Q$cc\E/;
    return undef if $n !~ /^\Q$cc\E[0-9A-Z]{2,12}\z/;
    if ( $cc eq 'GB' ) {
        return undef if $n !~ /^GB([0-9]{9})\z/ || !_gb_vat_ok($1);
    }
    return $n;
}

sub _gb_vat_ok ($d) {
    return 0 if $d =~ /^00/;
    my @w = ( 8, 7, 6, 5, 4, 3, 2 );
    my $sum = 0;
    $sum += substr( $d, $_, 1 ) * $w[$_] for 0 .. 6;
    my $r = $sum % 97;
    return substr( $d, 7, 2 ) eq ( $r ? sprintf( '%02d', 97 - $r ) : '00' );
}

# Per-field checks that hold a row; each answers whether a value satisfies it.
my %REQUIRE = (
    present => sub ($v) { ref $v eq 'ARRAY' ? scalar( grep { defined && /\S/ } @$v ) : ( defined $v && !ref $v && $v =~ /\S/ ) },
    email   => sub ($v) { defined $v && !ref $v && ( my @e = Odoo::Ops::Match::norm_email($v) ) ? 1 : 0 },
    number  => sub ($v) { defined $v && !ref $v && $v =~ /^\s*[-+]?(?:\d+(?:\.\d*)?|\.\d+)\s*\z/ ? 1 : 0 },
    date    => sub ($v) {
        return 0 if !defined $v || ref $v || $v !~ /^(\d{4})-(\d\d)-(\d\d)\z/;
        my ( $y, $m, $d ) = ( $1, $2, $3 );
        my @dim = ( 31, ( $y % 4 == 0 && ( $y % 100 || $y % 400 == 0 ) ? 29 : 28 ), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 );
        return $m >= 1 && $m <= 12 && $d >= 1 && $d <= $dim[ $m - 1 ] ? 1 : 0;
    },
);

# A require is one check or a list of them. Returns [ [name, fn], ... ].
# An empty value passes every check but 'present', so a field that is
# optional-but-valid-when-given is one check, and mandatory-and-valid is
# the list [present, email].
sub _compile_requires ($lf, $spec) {
    my @names = ref $spec eq 'ARRAY' ? @$spec : ($spec);
    Odoo::Error->throw( kind => 'usage', message => "mapping field '$lf': require is empty", fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' ) if !@names;
    return [ map {
        Odoo::Error->throw( kind => 'usage', message => "mapping field '$lf': require must be a name or a list of names", fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' ) if ref $_ || !length;
        [ $_, _compile_require( $lf, $_ ) ]
    } @names ];
}

sub _is_empty ($v) {
    return 1 if !defined $v;
    return !grep { defined && /\S/ } @$v if ref $v eq 'ARRAY';
    return !ref $v && $v !~ /\S/;
}

sub _compile_require ($lf, $req) {
    return $REQUIRE{$req} if $REQUIRE{$req};
    if ( $req =~ /^regex:(.+)\z/s ) {
        my $re = eval { qr/$1/ }
            or Odoo::Error->throw( kind => 'usage', message => "mapping field '$lf': require '$req' has an invalid pattern: " . ( $@ =~ s/ at \S+ line \d+.*//sr ), fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' );
        return sub ($v) { defined $v && !ref $v && $v =~ $re ? 1 : 0 };
    }
    Odoo::Error->throw( kind => 'usage', message => "mapping field '$lf': unknown require '$req' (present, email, number, date, regex:PATTERN)", fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' );
}

=head2 load($path, %opts)

Reads and checks a mapping. A transform that is unknown, has a bad
argument, or a C<require> that is unknown or has an invalid pattern,
refuses the mapping by field name. C<dbh> in C<%opts> is a database
handle for a C<dbi> reader (see below), used instead of connecting.

=cut

sub load ($class, $path, %opts) {
    my $m = eval { YAML::PP->new( schema => ['Core'] )->load_file($path) }
        or Odoo::Error->throw( kind => 'usage', message => "cannot load mapping $path: $@", fix => 'check the path exists and this user can read it' );
    for my $req (qw(source target reader fields)) {
        Odoo::Error->throw( kind => 'usage', message => "mapping $path missing '$req'", fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' )
            if !$m->{$req};
    }
    _check_lazysite_reader( $m->{reader} ) if ref $m->{reader} eq 'HASH' && ( $m->{reader}{kind} // '' ) eq 'lazysite-table';
    my $self = bless { mapping => $m, path => $path, base => dirname( File::Spec->rel2abs($path) ),
        map { exists $opts{$_} ? ( $_ => $opts{$_} ) : () } qw(dbh http retries now) }, $class;
    for my $lf ( sort keys %{ $m->{fields} } ) {
        my $spec = $m->{fields}{$lf};
        Odoo::Error->throw( kind => 'usage', message => "mapping field '$lf' needs one of from, template, const", fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' )
            if ref $spec ne 'HASH' || !grep { exists $spec->{$_} } qw(from template const);
        my @chain;
        for my $t ( @{ $spec->{transform} // [] } ) {
            my ( $name, $arg ) = $t =~ /^([a-z_]+)(?::(.*))?\z/s;
            $name //= '';
            if ( $TRANSFORM_ARG{$name} && defined $arg ) {
                push @chain, [ $TRANSFORM_ARG{$name}->( $arg, $lf ) ];
            }
            elsif ( $TRANSFORM{$name} && !defined $arg ) {
                my $fn = $TRANSFORM{$name};
                push @chain, [ sub ($v, $marks) { $fn->($v) }, 0 ];
            }
            else {
                Odoo::Error->throw( kind => 'usage',
                    message => "mapping field '$lf': " . ( $TRANSFORM_ARG{$name} ? "transform '$name' needs an argument ($name:...)" : "unknown transform '$t'" ),
                    fix => 'correct the transform in the mapping file' );
            }
        }
        $self->{chain}{$lf} = \@chain;
        if ( defined $spec->{require} ) {
            $self->{require}{$lf} = _compile_requires( $lf, $spec->{require} );
        }
    }
    return $self;
}

sub name    ($self) { $self->{mapping}{source} }
sub target  ($self) { $self->{mapping}{target} }
sub mapping ($self) { $self->{mapping} }
sub path    ($self) { $self->{path} }

sub field_policy ($self, $lf) { $self->{mapping}{fields}{$lf}{on_match} }
sub fields ($self) { sort keys %{ $self->{mapping}{fields} } }

sub rows ($self) {
    return $self->{rows} //= do {
        my @in  = $self->_read;
        my $ovr = $self->_overrides;
        my %have = map { ( "$_->{key}" => 1 ) } @in;
        my @stale = grep { !$have{$_} } sort keys %$ovr;
        Odoo::Error->throw( kind => 'usage',
            message => 'overrides name keys the source does not have: ' . join( ', ', @stale ),
            fix => 'remove those keys from the overrides file, or correct them to keys the source has' ) if @stale;
        [ map { $self->_map_row( $_, $ovr->{ "$_->{key}" } ) } @in ];
    };
}

sub _overrides ($self) {
    my $file = $self->{mapping}{overrides} or return {};
    my $path = $self->_abs($file);
    my $o = eval { YAML::PP->new( schema => ['Core'] )->load_file($path) } // {};
    Odoo::Error->throw( kind => 'usage', message => "cannot load overrides $path: $@", fix => 'check the path exists and this user can read it' ) if $@;
    Odoo::Error->throw( kind => 'usage', message => "overrides $path must map keys to entries", fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' )
        if ref $o ne 'HASH';
    for my $k ( sort keys %$o ) {
        my $e = $o->{$k};
        Odoo::Error->throw( kind => 'usage', message => "override '$k' needs set and/or hold", fix => 'correct the parameter or the file the message names, then plan again' )
            if ref $e ne 'HASH' || ( !$e->{set} && !$e->{hold} );
        Odoo::Error->throw( kind => 'usage', message => "override '$k' needs a why", fix => 'correct the parameter or the file the message names, then plan again' ) if !$e->{why};
    }
    return $o;
}

#--- readers ---------------------------------------------------------------------

sub _abs ($self, $p) { File::Spec->rel2abs( $p, $self->{base} ) }

sub _read ($self) {
    my $r    = $self->{mapping}{reader};
    my $kind = $r->{kind} // '';
    return $self->_read_dbi($r) if $kind eq 'dbi';
    return $self->_read_lazysite($r) if $kind eq 'lazysite-table';
    my $path = $self->_abs( $r->{path} // Odoo::Error->throw( kind => 'usage', message => 'reader needs path', fix => 'give the reader a path in the mapping file' ) );
    return $self->_read_json_dir( $r, $path ) if $kind eq 'json-dir';
    return $self->_read_jsonl( $r, $path )    if $kind eq 'jsonl';
    return $self->_read_csv( $r, $path )      if $kind eq 'csv';
    Odoo::Error->throw( kind => 'usage', message => "unknown reader kind '$kind'", fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' );
}

sub _envelope ($self, $r, $doc, $fallback_key) {
    my $rec   = defined $r->{record} ? _dig( $doc, $r->{record} ) : $doc;
    my $key   = defined $r->{key}    ? _dig( $doc, $r->{key} )    : $fallback_key;
    my $flags = defined $r->{flags}  ? _dig( $doc, $r->{flags} )  : [];
    return { key => $key // $fallback_key, record => $rec, flags => ref $flags eq 'ARRAY' ? $flags : [] };
}

sub _read_json_dir ($self, $r, $dir) {
    opendir my $dh, $dir or Odoo::Error->throw( kind => 'usage', message => "cannot open $dir: $!", fix => 'check the path exists and this user can read it' );
    my @files = sort grep { /\.json\z/ && -f File::Spec->catfile( $dir, $_ ) } readdir $dh;
    closedir $dh;
    return map {
        my $file = File::Spec->catfile( $dir, $_ );
        my $doc  = _read_json($file);
        +{ %{ $self->_envelope( $r, $doc, $_ =~ s/\.json\z//r ) }, file => $file }
    } @files;
}

sub _read_jsonl ($self, $r, $file) {
    open my $fh, '<:raw', $file or Odoo::Error->throw( kind => 'usage', message => "cannot read $file: $!", fix => 'check the path exists and this user can read it' );
    my @out;
    while ( my $line = <$fh> ) {
        next if $line !~ /\S/;
        my $doc = eval { Odoo::Ops::json()->decode($line) }
            // Odoo::Error->throw( kind => 'usage', message => "$file line $.: not JSON", fix => 'correct the file; oom-ops describe <op> shows what it holds' );
        push @out, $self->_envelope( $r, $doc, "line$." );
    }
    close $fh;
    return @out;
}

sub _read_csv ($self, $r, $file) {
    my $csv = Text::CSV_XS->new( { binary => 1, auto_diag => 0, sep_char => $r->{sep} // ',' } );
    open my $fh, '<:encoding(UTF-8)', $file
        or Odoo::Error->throw( kind => 'usage', message => "cannot read $file: $!", fix => 'check the path exists and this user can read it' );
    my $head = $csv->getline($fh) or Odoo::Error->throw( kind => 'usage', message => "$file has no header row", fix => 'correct the file; oom-ops describe <op> shows what it holds' );
    s/^\x{FEFF}// for $head->[0];
    my ( @out, $n );
    while ( my $cells = $csv->getline($fh) ) {
        $n++;
        next if !grep { defined && /\S/ } @$cells;
        my %rec;
        @rec{@$head} = @$cells;
        my $key = defined $r->{key} ? $rec{ $r->{key} } : undef;
        push @out, { key => $key // "row$n", record => \%rec, flags => [] };
    }
    Odoo::Error->throw( kind => 'usage', message => "$file: " . ( $csv->error_diag )[1], fix => 'correct the parameter or the file the message names, then plan again' )
        if !$csv->eof;
    close $fh;
    return @out;
}

# The result set of one SELECT as records. The handle is injected
# (load(..., dbh => $dbh)) or opened from the reader's credential file;
# DBI is loaded here, at run time, so the package does not depend on it.
sub _read_dbi ($self, $r) {
    for my $inline (qw(dsn user password)) {
        Odoo::Error->throw( kind => 'usage',
            message => "reader.$inline inline is refused; put dsn, user and password in a credential file and name it with 'credential'",
            fix => "move $inline into a credential file and name it with 'credential' in the mapping" )
            if exists $r->{$inline};
    }
    my $sql = $r->{sql} // Odoo::Error->throw( kind => 'usage', message => 'dbi reader needs sql', fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' );
    Odoo::Error->throw( kind => 'usage', message => 'dbi reader sql must be one SELECT (or WITH ... SELECT); Source never writes to a database', fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' )
        if $sql !~ /^\s*(?:select|with)\b/i || $sql =~ /;\s*\S/;
    my ( $dbh, $own ) = ( $self->{dbh}, 0 );
    if ( !$dbh ) {
        my $name = $r->{credential} // Odoo::Error->throw( kind => 'usage', message => 'dbi reader needs credential (a file of dsn, user, password lines)', fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' );
        my $c = Odoo::Ops::Credential->dsn( $self->_credential_path($name) );
        eval { require DBI; 1 }
            or Odoo::Error->throw( kind => 'config', message => 'the dbi reader needs the DBI module and a DBD driver (apt install libdbi-perl and the driver for the database)' );
        $dbh = eval { DBI->connect( $c->{dsn}, $c->{user}, $c->{password}, { RaiseError => 1, PrintError => 0, AutoCommit => 1 } ) };
        if ( !$dbh ) {
            my $why = $@ =~ s/\s+at \S+ line \d+.*//sr;
            $why =~ s/\Q$c->{password}\E/REMOVED/g if length( $c->{password} // '' );
            Odoo::Error->throw( kind => 'config', message => "dbi reader cannot connect to '$c->{dsn}': $why" );
        }
        $own = 1;
    }
    my @out;
    my $ok = eval {
        my $sth = $dbh->prepare($sql);
        $sth->execute;
        my $n = 0;
        while ( my $row = $sth->fetchrow_hashref('NAME') ) {
            $n++;
            Odoo::Error->throw( kind => 'usage', message => "dbi reader: key column '$r->{key}' is not in the result set (columns: " . join( ', ', sort keys %$row ) . ')', fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' )
                if defined $r->{key} && !exists $row->{ $r->{key} };
            my $key = defined $r->{key} ? $row->{ $r->{key} } : undef;
            push @out, { key => ( defined $key && length $key ? $key : "row$n" ), record => {%$row}, flags => [] };
        }
        $sth->finish;
        1;
    };
    my $err = $@;
    $dbh->disconnect if $own;
    if ( !$ok ) {
        die $err if ref $err;
        Odoo::Error->throw( kind => 'config', message => 'dbi reader query failed: ' . ( $err =~ s/\s+at \S+ line \d+.*//sr ) );
    }
    return @out;
}

# Checked at load so a mapping that carries a secret is refused before
# anything runs, whichever reader it names.
sub _check_lazysite_reader ($r) {
    for my $inline (qw(token partner password user)) {
        Odoo::Error->throw( kind => 'usage',
            message => "reader.$inline inline is refused; put partner, token and expires in a credential file (JSON, mode 600) and name it with 'credential'",
            fix => "move $inline into a credential file and name it with 'credential' in the mapping" )
            if exists $r->{$inline};
    }
    for my $need (qw(api credential table)) {
        Odoo::Error->throw( kind => 'usage', message => "lazysite-table reader needs $need", fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' )
            if !defined $r->{$need} || ref $r->{$need} || $r->{$need} eq '';
    }
    Odoo::Error->throw( kind => 'usage', message => "lazysite-table reader: where must map column names to values", fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' )
        if defined $r->{where} && ref $r->{where} ne 'HASH';
    Odoo::Error->throw( kind => 'usage', message => "lazysite-table reader: also must map a name to a table", fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' )
        if defined $r->{also} && ( ref $r->{also} ne 'HASH' || grep { !defined || ref } values %{ $r->{also} } );
    Odoo::Error->throw( kind => 'usage', message => "lazysite-table reader: also name '$_' is not a plain word (letters, digits, _)", fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' )
        for grep { !/^[A-Za-z]\w*\z/ } keys %{ $r->{also} // {} };
    return;
}

# One data-export per table (the reader's own, then each `also`); the
# reader's rows are the records and the other tables ride along as
# $self->{tables}, which templates and hold_when see as `tables`.
sub _read_lazysite ($self, $r) {
    _check_lazysite_reader($r);
    my $cred = Odoo::Ops::Credential->lazysite_token( $self->_credential_path( $r->{credential}, 'json' ), ( $self->{now} ? ( now => $self->{now} ) : () ) );
    my $site = Odoo::Ops::Source::Lazysite->new(
        api        => $r->{api},
        credential => $cred,
        http       => $self->{http},
        ( defined $self->{retries} ? ( retries => $self->{retries} ) : () ),
        ( map { defined $r->{$_} ? ( $_ => $r->{$_} ) : () } qw(ssl_ca_file ssl_verify timeout) ),
    );
    my $rows = $site->rows( $r->{table} );
    my %also = %{ $r->{also} // {} };
    $self->{tables} = { map { ( $_ => $site->rows( $also{$_} ) ) } sort keys %also };
    my %where = %{ $r->{where} // {} };
    my ( @out, $n );
    for my $row (@$rows) {
        $n++;
        next if ref $row ne 'HASH';
        next if grep {
            my ( $col, $want ) = ( $_, $where{$_} );
            my $have = $row->{$col};
            my @ok = ref $want eq 'ARRAY' ? @$want : ($want);
            !( defined $have && grep { defined && "$have" eq "$_" } @ok );
        } sort keys %where;
        Odoo::Error->throw( kind => 'usage', message => "lazysite-table reader: key column '$r->{key}' is not in table '$r->{table}' (columns: " . join( ', ', sort keys %$row ) . ')', fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' )
            if defined $r->{key} && !exists $row->{ $r->{key} };
        my $key = defined $r->{key} ? $row->{ $r->{key} } : undef;
        push @out, { key => ( defined $key && length $key ? $key : "row$n" ), record => {%$row}, flags => [] };
    }
    return @out;
}

# a credential is a path (relative to the mapping) or a bare name:
# NAME.EXT beside the mapping, else under $OOM_CREDENTIALS_DIR
sub _credential_path ($self, $name, $ext = 'dsn') {
    return $self->_abs($name) if $name =~ m{/};
    my @try = ( $self->_abs("$name.$ext"), ( defined $ENV{OOM_CREDENTIALS_DIR} ? File::Spec->catfile( $ENV{OOM_CREDENTIALS_DIR}, "$name.$ext" ) : () ) );
    for my $p (@try) { return $p if -e $p }
    return $try[0];
}

sub _read_json ($file) {
    open my $fh, '<:raw', $file or Odoo::Error->throw( kind => 'usage', message => "cannot read $file: $!", fix => 'check the path exists and this user can read it' );
    my $raw = do { local $/; <$fh> };
    close $fh;
    return eval { Odoo::Ops::json()->decode($raw) }
        // Odoo::Error->throw( kind => 'usage', message => "$file is not valid JSON", fix => 'correct the file; oom-ops describe <op> shows what it holds' );
}

sub _dig ($doc, $path) {
    my $v = $doc;
    for my $k ( split /\./, $path ) {
        return undef if ref $v ne 'HASH';
        $v = $v->{$k};
    }
    return $v;
}

#--- mapping -----------------------------------------------------------------------

sub _map_row ($self, $in, $ovr = undef) {
    my $m   = $self->{mapping};
    my %row = ( key => "$in->{key}", flags => $in->{flags}, ( $in->{file} ? ( file => $in->{file} ) : () ) );
    my %hold = map { $_ => 1 } @{ $m->{hold_flags} // [] };
    if ( my ($f) = grep { $hold{$_} } @{ $in->{flags} } ) {
        $row{held} = "flag:$f";
    }
    my $rec = $in->{record};
    if ( ref $rec ne 'HASH' ) {
        $row{error} = 'no record at ' . ( $m->{reader}{record} // 'top level' );
        return \%row;
    }
    if ($ovr) {
        $rec = { %$rec, %{ $ovr->{set} // {} } };
        $row{overridden} = $ovr->{why};
        $row{held} //= "override:$ovr->{hold} - $ovr->{why}" if $ovr->{hold};
    }
    if ( !$row{held} ) {
        for my $rule ( @{ $m->{hold_when} // [] } ) {
            my $out = '';
            my $tt  = $self->{tt} //= Template->new( { ENCODING => 'utf8' } );
            $tt->process( \"[% IF ($rule->{if}) %]1[% END %]", { %$rec, ( $self->{tables} ? ( tables => $self->{tables} ) : () ) }, \$out )
                or Odoo::Error->throw( kind => 'usage', message => "hold_when '$rule->{if}': " . $tt->error, fix => 'correct the mapping file the message names (oom-ops mapping-skeleton shows the shape)' );
            if ( $out eq '1' ) { $row{held} = "rule:$rule->{reason}"; last }
        }
    }
    my ( %values, @why, @marks );
    for my $lf ( sort keys %{ $m->{fields} } ) {
        my $spec = $m->{fields}{$lf};
        my @fm;
        my $v = eval { $self->_value( $lf, $spec, $rec, $row{key}, \@fm ) };
        if ( !defined $v && $@ ) {
            $row{error} = "field $lf: " . ( $@ =~ s/\s+\z//r );
            last;
        }
        $values{$lf} = $v;
        for my $mark (@fm) {
            push @marks, $mark if !grep { $_ eq $mark } @marks;
            push @why, "$lf $mark";
        }
        for my $req ( @{ $self->{require}{$lf} // [] } ) {
            my ( $rname, $fn ) = @$req;
            next if $rname ne 'present' && _is_empty($v);
            push @why, "$lf $rname failed" if !$fn->($v);
        }
    }
    $row{values} = \%values;
    $row{invalid} = \@marks if @marks;
    # a mapping-level hold never replaces a person's or a source's: it
    # only holds a row nothing else held, and lists every failure
    $row{held} = 'rule:' . join( '; ', @why ) if @why && !$row{held} && !defined $row{error};
    return \%row;
}

sub _value ($self, $lf, $spec, $rec, $key, $marks = []) {
    my $v;
    if    ( exists $spec->{const} ) { $v = $spec->{const} }
    elsif ( exists $spec->{from} )  { $v = _dig( $rec, $spec->{from} ) }
    else {
        my $out = '';
        my $tt  = $self->{tt} //= Template->new( { ENCODING => 'utf8' } );
        $tt->process( \$spec->{template}, { %$rec, source_key => $key, ( $self->{tables} ? ( tables => $self->{tables} ) : () ) }, \$out )
            or die $tt->error . "\n";
        $v = $out =~ s/^\s+|\s+\z//gr;
    }
    for my $step ( @{ $self->{chain}{$lf} // [] } ) {
        my ( $fn, $whole ) = @$step;
        $v = ref $v eq 'ARRAY' && !$whole ? [ map { $fn->( $_, $marks ) } @$v ] : $fn->( $v, $marks );
    }
    if ( ref $v eq 'ARRAY' ) {
        my $map = $spec->{map} // {};
        $v = [ grep { defined && length } map { exists $map->{$_} ? $map->{$_} : $_ } @$v ];
        push @$v, grep { my $a = $_; !grep { $_ eq $a } @$v } @{ $spec->{add} // [] };
    }
    elsif ( defined $v && $spec->{map} && exists $spec->{map}{$v} ) {
        $v = $spec->{map}{$v};
    }
    $v = undef if defined $v && !ref $v && $v eq '';
    return $v;
}

1;
