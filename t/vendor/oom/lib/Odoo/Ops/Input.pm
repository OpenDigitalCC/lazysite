package Odoo::Ops::Input;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;

our $VERSION = '0.44';

=head1 NAME

Odoo::Ops::Input - a size bound on every file or body an outside party can supply

=head1 SYNOPSIS

    Odoo::Ops::Input->configure( $config->get('max_input_bytes') );
    Odoo::Ops::Input->check_file( $path, 'stock.link_stranded' );     # before any byte is parsed
    my $raw = Odoo::Ops::Input->slurp( $path, $who );                 # read at most the bound
    Odoo::Ops::Input->check_text( $text, 'rows', $who );
    Odoo::Ops::Input->bound;                                          # 67108864 unless configured

=head1 DESCRIPTION

The CSV, JSON and YAML parsers OOM binds (L<Text::CSV_XS>, the JSON backend,
L<YAML::PP>) have had memory-exhaustion advisories; a file a counterparty or a
caller hands over is read by them. This module refuses an oversized input
before the parser sees a byte, as C<refused/input-too-large>, naming the size
and the bound.

The bound is the ops config's C<max_input_bytes> (default 64 MiB, 67108864),
set once per process by L<Odoo::Ops::Context> and C<oom-ops>. An operation that
already declares a smaller bound of its own (a file parameter's C<max_bytes>)
keeps it and answers with its own code first; a caller may also pass
C<< max => N >> to the checks here. A row count is not bounded.

=cut

use constant DEFAULT => 64 * 1024 * 1024;

my $BOUND = DEFAULT;

=head2 configure($bytes)

Set the process-wide bound; undef restores the default. A value that is not a
whole number above 0 is a C<config> error.

=cut

sub configure ($class, $bytes = undef) {
    if ( !defined $bytes ) { $BOUND = DEFAULT; return $BOUND }
    Odoo::Error->throw( kind => 'config', message => "max_input_bytes must be a whole number of bytes, not '$bytes'" )
        if $bytes !~ /\A[1-9]\d*\z/;
    return $BOUND = 0 + $bytes;
}

=head2 bound

The bound in force, in bytes.

=cut

sub bound ($class) { $BOUND }

sub _refuse ($what, $size, $max, $who) {
    my $head = defined $who && length $who ? "$who: " : '';
    Odoo::Error->throw( kind => 'refused', code => 'input-too-large',
        message => "$head$what is $size bytes; the limit is $max (max_input_bytes)",
        fix => 'give a smaller file or split it; the ops config key max_input_bytes raises the limit' );
}

=head2 check_file($path, $who, max => N)

Refuse, before it is opened, a file larger than the bound. A path that is not
a file is left to the caller's own error.

=cut

sub check_file ($class, $path, $who = undef, %o) {
    my $max = $o{max} // $BOUND;
    return 1 if !defined $path || !-f $path;
    my $size = -s _;
    _refuse( $path, $size, $max, $who ) if $size > $max;
    return 1;
}

=head2 check_text($text, $label, $who, max => N)

Refuse text or bytes (a C<--set> value, a body) longer than the bound.

=cut

sub check_text ($class, $text, $label, $who = undef, %o) {
    my $max = $o{max} // $BOUND;
    return 1 if !defined $text || ref $text;
    my $size = length $text;
    _refuse( $label, $size, $max, $who ) if $size > $max;
    return 1;
}

=head2 slurp($path, $who, max => N)

The raw bytes of a file, after C<check_file>, reading at most the bound plus
one byte so a file that grows after the check is still refused.

=cut

sub slurp ($class, $path, $who = undef, %o) {
    my $max = $o{max} // $BOUND;
    $class->check_file( $path, $who, max => $max );
    open my $fh, '<:raw', $path
        or Odoo::Error->throw( kind => 'usage', message => "cannot read $path: $!", fix => 'check the path exists and this user can read it' );
    my $n = read( $fh, my $raw, $max + 1 );
    close $fh;
    _refuse( $path, $n, $max, $who ) if ( $n // 0 ) > $max;
    return $raw // '';
}

1;
