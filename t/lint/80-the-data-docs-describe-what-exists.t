#!/usr/bin/perl
# DP-8: the data-plugin docs name tools, actions and types that exist.
#
# DOCS ARE THE ONE SURFACE WITH NO RUNTIME. Code that names a tool wrongly
# fails; prose that does is read, believed, and acted on - and the reader is
# usually an agent or an operator who cannot check. SM435 is that defect on the
# capability descriptor and SM457 is it pointed the other way; this is the same
# question asked of documentation.
#
# IT CHECKS NAMES, NOT PROSE. Whether the explanation is good is a judgement a
# test cannot make. Whether `save_data_table` is a real tool is not, and that is
# what goes stale first - a rename lands in the code, the gate stays green, and
# the docs quietly describe a door that no longer opens.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                    qw(repo_root);
use Lazysite::ControlApi::Actions ();
use Lazysite::Data::Descriptor    ();

my $root = repo_root();
my @docs = ( "$root/starter/docs/data-tables.md",
    "$root/starter/docs/ai-briefing-data.md" );
plan skip_all => 'data docs missing' unless -f $docs[0] && -f $docs[1];

my $text = '';
for my $d (@docs) {
    open my $fh, '<', $d or die "$d: $!";
    local $/;
    $text .= <$fh>;
}

subtest 'every MCP tool the docs name exists' => sub {
    my $mcp = do {
        open my $fh, '<', "$root/lazysite-mcp.pl" or die $!;
        local $/;
        <$fh>;
    };
    my %tool = map { $_ => 1 } $mcp =~ /^    (\w+) => \{$/mg;
    ok( scalar keys %tool, 'the tool table was found (test not vacuous)' )
        or BAIL_OUT('no tools parsed - this test would pass while checking nothing');

    # ANY backticked snake_case token that mentions `data`, plus the one tool
    # that does not. An earlier version matched only names beginning with a
    # known verb - save_, read_, list_ and so on - so an invented tool called
    # anything else was not captured at all, and the check passed by not
    # looking. An allow-list of verbs is a guess about how the next tool will
    # be named.
    my %named;
    $named{$1} = 1 while $text =~ /`([a-z][a-z0-9_]*data[a-z0-9_]*)`/g;
    $named{$1} = 1 while $text =~ /`(preview_public_page)`/g;
    # CAPABILITY names are not tool names, and `manage_data` is both mentioned
    # and a legitimate thing to mention. Excluded from the shared list rather
    # than by name, so a future capability does not have to be remembered here.
    require Lazysite::Auth::Settings;
    delete $named{$_} for @Lazysite::Auth::Settings::CAP_KEYS;
    delete $named{$_} for qw(data data_tables);
    ok( scalar keys %named, 'the docs name some tools' );
    for my $t ( sort keys %named ) {
        ok( $tool{$t}, "$t is a real tool" )
            or diag( 'The docs tell an agent to call this. An agent cannot '
                . 'check, so a wrong name here is acted on rather than '
                . 'noticed.' );
    }

    # AND THE OTHER DIRECTION. A tool nobody documents is a tool an agent does
    # not know it has, which is SM457's under-claiming defect wearing prose.
    my @data_tools = sort grep { /data/ } keys %tool;
    for my $t (@data_tools) {
        ok( $text =~ /\Q$t\E/, "$t is documented somewhere" );
    }
};

subtest 'every control-API action the docs name exists' => sub {
    my $actions = \%Lazysite::ControlApi::Actions::ACTION;
    ok( scalar keys %{$actions}, 'the action table was found' )
        or BAIL_OUT('no actions - this test would prove nothing');

    my %named;
    $named{$1} = 1 while $text =~ /`(data-[a-z-]+)`/g;
    $named{$1} = 1 while $text =~ /action=(data-[a-z-]+)/g;
    ok( scalar keys %named, 'the docs name some actions' );
    for my $a ( sort keys %named ) {
        ok( $actions->{$a}, "$a is a real action" );
    }
};

subtest 'every field type the docs document is a real type' => sub {
    my @real = Lazysite::Data::Descriptor::TYPES();
    my %real = map { $_ => 1 } @real;
    ok( scalar @real, 'the type list was found' );

    # The operator doc lists types as definition terms; check each is real, and
    # that none is MISSING - an undocumented type is a feature nobody finds.
    my $ops = do {
        open my $fh, '<', $docs[0] or die $!;
        local $/;
        <$fh>;
    };
    my ($section) = $ops =~ /## Field types\n(.*?)\n## /s;
    ok( defined $section, 'the field-types section is present' ) or return;

    my %documented;
    $documented{$1} = 1 while $section =~ /^`(\w+)`$/mg;
    for my $t ( sort keys %documented ) {
        ok( $real{$t}, "`$t` is a real field type" );
    }
    my @undocumented = sort grep { !$documented{$_} } @real;
    is_deeply( \@undocumented, [],
        'and every real type is documented' )
        or diag( join "\n  ", '', @undocumented, '',
        'A type nobody documents is a feature nobody finds, and the next '
            . 'person adds a worse way of doing the same thing.' );
};

subtest 'the paths the docs name are the paths the code uses' => sub {
    require Lazysite::Data::Connect;
    my $store = Lazysite::Data::Connect::store_path('/D');
    like( $store, qr{/lazysite/db/}, 'the store lives under lazysite/db' );
    like( $text, qr{lazysite/db/data\.sqlite},
        'and the docs name it' );

    require Lazysite::Data::Tables;
    my $dir = Lazysite::Data::Tables::descriptor_dir('/D');
    like( $dir, qr{/lazysite/db/tables\z}, 'descriptors live in db/tables' );
    like( $text, qr{lazysite/db/tables/}, 'and the docs name that too' )
        or diag( 'A wrong path sends somebody to create a file in a place '
            . 'nothing reads.' );
};

done_testing();
