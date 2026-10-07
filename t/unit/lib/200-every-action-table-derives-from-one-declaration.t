#!/usr/bin/perl
# SM943 stage 1: every per-action table in lazysite-manager-api.pl is derived from
# the one declaration in Lazysite::ControlApi::Actions.
#
# THIS IS THE PROOF THE FILING ASKS FOR - "a test proves the derived tables
# equal today's hand-kept ones before any copy is removed". It reads the CGI's
# literal tables out of its source and requires each derived table to equal it
# exactly: same keys, same values, nothing extra in either direction.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                    qw(repo_root);
use Lazysite::ControlApi::Actions ();

my $src = do {
    open my $fh, '<', repo_root() . '/lazysite-manager-api.pl' or die $!;
    local $/;
    <$fh>;
};

sub literal_set {
    my ($name) = @_;
    my ($b)    = $src =~ /my \%\Q$name\E = map \{ \$_ => 1 \} qw\((.*?)\);/s;
    return undef unless defined $b;
    return { map { $_ => 1 } split ' ', $b };
}

sub literal_hash {
    my ($name) = @_;
    my ($b)    = $src =~ /\n *my \%\Q$name\E = \((.*?)\n *\);/s;
    return undef unless defined $b;
    my %h = eval "($b)";    ## no critic (ProhibitStringyEval) - a pure literal
    die "$name: $@" if $@;
    return \%h;
}

my $A     = 'Lazysite::ControlApi::Actions';
my @pairs = (
    [ KNOWN_ACTION        => \&literal_set,  'known_actions' ],
    [ SCOPED_ACTION       => \&literal_set,  'scoped_actions' ],
    [ MUTATING            => \&literal_set,  'mutating' ],
    [ DESTRUCTIVE         => \&literal_set,  'destructive' ],
    [ CHANGES_ACCESS      => \&literal_set,  'changes_access' ],
    [ skip                => \&literal_set,  'unaudited' ],
    [ COOKIE_CAP          => \&literal_hash, 'cookie_caps' ],
    [ COOKIE_GATES_ITSELF => \&literal_hash, 'cookie_gates_itself' ],
    [ COOKIE_ONLY_REASON  => \&literal_hash, 'cookie_only_reasons' ],
    [ file_surface        => \&literal_hash, 'file_surface' ],
);

for my $p (@pairs) {
    my ( $table, $reader, $fn ) = @$p;
    my $literal = $reader->($table);
    ok( $literal && %$literal, "%$table is read from the CGI's source" ) or next;
    my %derived = $A->can($fn)->();
    is_deeply( \%derived, $literal,
        "$fn() equals the hand-kept %$table exactly ("
            . scalar( keys %$literal ) . ' entries)' );
}

done_testing();
