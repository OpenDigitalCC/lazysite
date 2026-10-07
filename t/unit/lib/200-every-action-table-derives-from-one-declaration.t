#!/usr/bin/perl
# SM943 stage 1: every per-action table in lazysite-manager-api.pl is derived from
# the one declaration in Lazysite::ControlApi::Actions.
#
# THE EQUALITY PROOF CAME FIRST. The commit that added the fields to %ACTION
# carried this test in its first form: it read all ten literal tables out of the
# CGI's source and required each derived table to equal it exactly (is_deeply,
# 20/20), which is the filing's "a test proves the derived tables equal today's
# hand-kept ones before any copy is removed". The next commit removed the copies,
# so there is nothing left to compare against; this form pins what replaced them.
#
#   1. the CGI builds each table from the module, and declares none of its own;
#   2. the declaration holds the facts the gates rely on (spot checks, each a
#      reason a table existed);
#   3. every name a derived table holds is a declared action, and the
#      relationships two tables used to keep by hand still hold.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                    qw(repo_root);
use Lazysite::ControlApi::Actions ();

my $A   = 'Lazysite::ControlApi::Actions';
my $src = do {
    open my $fh, '<', repo_root() . '/lazysite-manager-api.pl' or die $!;
    local $/;
    <$fh>;
};

my %FROM = (
    KNOWN_ACTION        => 'known_actions',
    SCOPED_ACTION       => 'scoped_actions',
    MUTATING            => 'mutating',
    DESTRUCTIVE         => 'destructive',
    CHANGES_ACCESS      => 'changes_access',
    skip                => 'unaudited',
    COOKIE_CAP          => 'cookie_caps',
    COOKIE_GATES_ITSELF => 'cookie_gates_itself',
    COOKIE_ONLY_REASON  => 'cookie_only_reasons',
    file_surface        => 'file_surface',
);

subtest 'the CGI builds every per-action table from the declaration' => sub {
    for my $t ( sort keys %FROM ) {
        my @decl = $src =~ /\bmy \%\Q$t\E\s*=\s*([^;]*);/g;
        is( scalar @decl, 1, "%$t is declared once" );
        is( $decl[0] // '', "Lazysite::ControlApi::Actions::$FROM{$t}()",
            "%$t = $FROM{$t}() - no literal copy" );
        ok( $A->can( $FROM{$t} ), "$FROM{$t}() exists" );
    }
};

my %known  = $A->can('known_actions')->();
my %mut    = $A->can('mutating')->();
my %destr  = $A->can('destructive')->();
my %ca     = $A->can('changes_access')->();
my %scoped = $A->can('scoped_actions')->();
my %skip   = $A->can('unaudited')->();
my %cc     = $A->can('cookie_caps')->();
my %selfg  = $A->can('cookie_gates_itself')->();
my %cor    = $A->can('cookie_only_reasons')->();
my %fs     = $A->can('file_surface')->();

subtest 'the declaration says what the gates rely on' => sub {
    # SM958: the action whose missing cookie line opened it to any manager.
    ok( $mut{'form-uploads-save'}, 'form-uploads-save is mutating (POST-only)' );
    # It has no cookie_cap of its own: the cookie gate falls back to its token
    # gate (SM958) unless the action gates itself - the rule the CGI applies.
    my $g = $Lazysite::ControlApi::Actions::GATE{'form-uploads-save'};
    my $cookie_need
        = $cc{'form-uploads-save'}
        // ( $selfg{'form-uploads-save'} ? undef : join '|', @{ $g || [] } );
    is( $cookie_need, 'manage_forms', 'form-uploads-save is cookie-gated on manage_forms' );
    ok( $skip{'form-uploads-save'} ? 0 : 1, 'form-uploads-save is audited' );
    # SM660: an all-of gate keeps its `+`.
    is( $cc{'form-submission-delete'}, 'manage_forms+read_submissions',
        'form-submission-delete needs BOTH capabilities on the cookie channel' );
    ok( $destr{'form-submission-delete'}, 'form-submission-delete is destructive' );
    # SM587: acl-remove changes access and is not destructive.
    ok( $ca{'acl-remove'} && !$destr{'acl-remove'},
        'acl-remove changes access and is not destructive' );
    ok( $ca{'domain-set'},     'domain-set changes access (SM647)' );
    ok( !$ca{'preview-grant'}, 'preview-grant does not change access (SM649)' );
    # SM418: keyed by the dispatched name.
    is( $fs{'file-upload'}, 'write', 'file-upload is a write on the file surface' );
    ok( !exists $fs{upload}, 'and nothing is keyed by the old name `upload`' );
    is( $fs{'file-zip-download'}, 'read', 'the zip is a read on the file surface (SM517)' );
    ok( $scoped{read} && $scoped{save}, 'read and save are confined by dav_scope' );
    ok( $selfg{'acl-set'},          'acl-set decides for itself on the cookie channel' );
    ok( $cor{'rotate-auth-secret'}, 'rotate-auth-secret says why it is cookie-only' );
    # The audit default and its exceptions.
    ok( !$skip{'data-row-save'},   'a data write is audited by default' );
    ok( $skip{'data-rows'},        'a data read is not' );
    ok( $skip{'cache-invalidate'}, 'cache-invalidate mutates and is declared unaudited' );
    ok( !$skip{'file-download'},   'file-download reads and is declared audited' );
    ok( $known{'csrf-token'} && $skip{'csrf-token'}, 'csrf-token is known and unaudited' );
};

subtest 'every derived table names declared actions, and the old pairings hold' => sub {
    for my $pair ( [ MUTATING => \%mut ], [ DESTRUCTIVE => \%destr ],
        [ CHANGES_ACCESS     => \%ca ], [ SCOPED_ACTION => \%scoped ], [ skip => \%skip ],
        [ COOKIE_CAP         => \%cc ],  [ COOKIE_GATES_ITSELF => \%selfg ],
        [ COOKIE_ONLY_REASON => \%cor ], [ file_surface        => \%fs ] )
    {
        my ( $t, $h ) = @$pair;
        my @stray = grep { !$known{$_} } sort keys %$h;
        is( "@stray", '', "every %$t key is a declared action" );
    }
    is( scalar keys %known, scalar keys %Lazysite::ControlApi::Actions::ACTION,
        '%KNOWN_ACTION is exactly the declared set' );
    # Each was a relationship between two hand-kept tables; now one entry, still a rule.
    my @d = grep { !$mut{$_} } sort keys %destr;
    is( "@d", '', 'every destructive action mutates' );
    my @c = grep { !$mut{$_} } sort keys %ca;
    is( "@c", '', 'every access-changing action mutates' );
    my @w = grep { $fs{$_} eq 'write' && !$mut{$_} } sort keys %fs;
    is( "@w", '', 'every file-surface write mutates' );
    my @r = grep { $fs{$_} eq 'read' && $mut{$_} } sort keys %fs;
    is( "@r", '', 'no file-surface read mutates' );
    my @mixed = grep { $cc{$_} =~ /\|/ && $cc{$_} =~ /\+/ } sort keys %cc;
    is( "@mixed", '', 'no cookie_cap mixes any-of and all-of' );
    my @both = grep { $cc{$_} } sort keys %selfg;
    is( "@both", '', 'an action that gates itself names no cookie capability' );
};

# SM943 stage 2, THE EQUALITY PROOF FOR THE MCP SIDE. The hand-kept tables are
# read out of their sources as they stand - t/lint/23's %PAIR, lazysite-mcp.pl's
# %ANNOTATE and %READ - and each derived table must equal its literal exactly.
# The next commit switches the code to the derived tables.
subtest 'SM943 stage 2: the derived MCP tables equal the hand-kept ones' => sub {
    my $slurp = sub { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> };
    my $mcp   = $slurp->( repo_root() . '/lazysite-mcp.pl' );
    my $l23   = $slurp->( repo_root() . '/t/lint/23-mcp-api-action-parity.t' );

    my ($pb) = $l23 =~ /^my %PAIR = \(\n(.*?)^\);/ms;
    my %PAIR = ( $pb // '' ) =~ /^\s*'([a-z_-]+)'\s*=>\s*'([a-z_]+)',/mg;
    is( scalar keys %PAIR, 60, "lint 23's %PAIR read: 60 twins" );
    my %twins = $A->can('mcp_twins')->();
    is_deeply( \%twins, \%PAIR, 'mcp_twins() is exactly lint 23\'s %PAIR' );

    # %ANNOTATE as written, a missing fourth slot read as 0 (tool_list's reading).
    # Four tools were written twice; a duplicate must agree with itself or the
    # later row silently won.
    my ($ab) = $mcp =~ /^my %ANNOTATE = \((.*?)^\);/ms;
    my ( %LIT, @dup_disagree, $rows );
    while ( ( $ab // '' ) =~ /^\s*([a-z_]+)\s*=>\s*\[([^\]]*)\]/mg ) {
        my ( $t, @v ) = ( $1, map { s/\s//gr } split /,/, $2 );
        $v[3] //= 0;
        $rows++;
        push @dup_disagree, $t if $LIT{$t} && "@{$LIT{$t}}" ne "@v";
        $LIT{$t} = [ map { 0 + $_ } @v ];
    }
    is( $rows,            88, '%ANNOTATE read: 88 rows' );
    is( scalar keys %LIT, 84, '84 tools - four are written twice' );
    is( "@dup_disagree",  '', 'and each duplicate agrees with itself' );

    my %ann = $A->can('mcp_annotations')->();
    is( scalar keys %ann, 60, 'mcp_annotations() covers every twin' );
    for my $t ( sort keys %ann ) {
        is_deeply( $ann{$t}, $LIT{$t}, "$t: derived hints equal %ANNOTATE's row" );
    }
    my %derived = ( ( map { $_ => $LIT{$_} } grep { !$ann{$_} } keys %LIT ), %ann );
    is_deeply( \%derived, \%LIT,
        'the twins\' derived rows plus the rest as written ARE %ANNOTATE' );

    # %READ, the audit's skip list: today it is the read-only tools minus these
    # seventeen, which the MCP trail records although they read.
    my %AUDITED_READ = map { $_ => 1 } qw(
        describe_capabilities describe_data_table list_briefs list_data_safety_exports
        list_data_tables list_domains list_layout_catalogue plan_data_migration
        preview_domain preview_public_page read_brief read_data_rows
        read_data_safety_export read_data_table_source read_form_submission
        read_form_submissions read_notices
    );
    my ($rb) = $mcp =~ /^my %READ = \((.*?)\);/ms;
    my %READ = map { $_ => 1 } ( $rb // '' ) =~ /([a-z_]+)\s*=>\s*1/g;
    is( scalar keys %READ, 22, '%READ read: 22 tools' );
    my %read_derived
        = map { $_ => 1 } grep { $derived{$_}[0] && !$AUDITED_READ{$_} } keys %derived;
    is_deeply( \%read_derived, \%READ,
        '%READ is the read-only tools less the seventeen audited reads' );
};

done_testing();
