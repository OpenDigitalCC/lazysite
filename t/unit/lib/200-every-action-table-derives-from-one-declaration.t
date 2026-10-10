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

# SM944 S25: the effects actions-list and describe-capabilities publish moved to
# Manager::Describe, which derives the three tables _action_effects reads from
# the same declaration. Held the same way, so the published effects cannot
# drift from the gates through a literal copy there either.
subtest 'Manager::Describe builds the effects tables from the declaration' => sub {
    my $mod = do {
        open my $fh, '<', repo_root() . '/lib/Lazysite/Manager/Describe.pm' or die $!;
        local $/;
        <$fh>;
    };
    for my $t (qw(MUTATING DESTRUCTIVE CHANGES_ACCESS)) {
        my @decl = $mod =~ /\bmy \%\Q$t\E\s*=\s*([^;]*);/g;
        is( scalar @decl, 1, "Describe: %$t is declared once" );
        is( $decl[0] // '', "Lazysite::ControlApi::Actions::$FROM{$t}()",
            "Describe: %$t = $FROM{$t}() - no literal copy" );
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
    # SM978: page-pdf is the one exception, named. It READS pages (scoped, and
    # so on the file surface - lint 14), and is POST-only because it runs a
    # converter and writes a cached PDF (SM732).
    my %READ_THAT_MUTATES = ( 'page-pdf' => 'reads pages; runs a converter and caches the PDF' );
    my @r = grep { $fs{$_} eq 'read' && $mut{$_} && !$READ_THAT_MUTATES{$_} } sort keys %fs;
    is( "@r", '', 'no file-surface read mutates, but the named exception' );
    ok( $fs{$_} eq 'read' && $mut{$_}, "$_ is still a mutating file-surface read" )
        for sort keys %READ_THAT_MUTATES;
    my @mixed = grep { $cc{$_} =~ /\|/ && $cc{$_} =~ /\+/ } sort keys %cc;
    is( "@mixed", '', 'no cookie_cap mixes any-of and all-of' );
    my @both = grep { $cc{$_} } sort keys %selfg;
    is( "@both", '', 'an action that gates itself names no cookie capability' );
};

# SM943 stage 2: THE MCP SIDE IS DERIVED TOO. The equality proof came first: the
# commit that declared `mcp` and `mcp_open_world` carried this subtest in a form
# that read t/lint/23's %PAIR and lazysite-mcp.pl's %ANNOTATE and %READ out of
# their sources and required each derived table to equal its literal - 60 twins,
# 84 annotated tools (88 rows: four were written twice, alike), 22 unaudited
# tools. The literals are gone, so this pins what replaced them, as subtest 1
# does for the CGI.
subtest 'SM943 stage 2: the MCP tables are built from the declaration' => sub {
    my $slurp = sub { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> };
    my $mcp   = $slurp->( repo_root() . '/lazysite-mcp.pl' );
    my $l23   = $slurp->( repo_root() . '/t/lint/23-mcp-api-action-parity.t' );

    my @ann = $mcp =~ /\bmy %ANNOTATE\s*=\s*([^;]*);/g;
    is_deeply( \@ann, ['Lazysite::ControlApi::Actions::mcp_annotations()'],
        '%ANNOTATE starts from mcp_annotations() - no literal copy of a twin' );
    my @read = $mcp =~ /\bmy %READ\s*=\s*([^;]*);/g;
    is_deeply( \@read,
        [q{map { $_ => 1 } grep { $ANNOTATE{$_}[0] } keys %ANNOTATE}],
        '%READ is the read-only tools, with no named exceptions (SM943 ruling 1)' );
    my @pair = $l23 =~ /\bmy %PAIR\s*=\s*([^;]*);/g;
    is_deeply( \@pair, ['Lazysite::ControlApi::Actions::mcp_twins()'],
        'lint 23 pairs the twins the declaration names - no %PAIR of its own' );

    # What the dispatch then holds, rebuilt the way it builds it.
    my ($own) = $mcp =~ /^my %OWN_ANNOTATE = \((.*?)^\);/ms;
    my %ANN = $A->can('mcp_annotations')->();
    while ( ( $own // '' ) =~ /^\s*([a-z_]+)\s*=>\s*\[([^\]]*)\]/mg ) {
        my ( $t, @v ) = ( $1, map { s/\s//gr } split /,/, $2 );
        $ANN{$t} = \@v;
    }
    # SM943 ruling 1 (2026-10-09) dropped the seventeen reads this trail recorded
    # while the API skipped their twins: "Drop all 17."
    unlike( $mcp, qr/%AUDITED_READ/, 'no list of audited reads is kept' );
    my %READ = map { $_ => 1 } grep { $ANN{$_}[0] } keys %ANN;

    # The audit decisions.
    ok( $READ{list_files} && $READ{whoami} && $READ{list_versions},
        'plain reads are not audited' );
    ok( $READ{read_form_submissions} && $READ{read_data_rows} && $READ{describe_capabilities},
        'nor are the submission, row and capability reads, which once were (ruling 1)' );
    ok( !$READ{save_data_row} && !$READ{delete_file},
        'a write is audited' );
    ok( !$READ{regenerate_registries},
        'regenerate_registries is audited here, though its API twin is not' );

    # The hints, from the act.
    is_deeply( $ANN{set_permissions}, [ 0, 0, 0, 1 ],
        "set_permissions moves the read boundary, as acl-set does" );
    is_deeply( $ANN{site_apply}, [ 0, 1, 1, 0 ], 'site_apply is destructive, as site-backup-apply is' );
    is_deeply( $ANN{connector_call}, [ 0, 0, 1, 0 ], 'connector_call is open-world' );
    is_deeply( $ANN{read_notices},   [ 1, 0, 0, 0 ], 'read_notices is read-only' );
};

# SM943 stage 3: THE ONE COMPLETENESS CHECK. With every per-action table derived
# from %ACTION, the lints that kept copies in step (14, 22, 23, 58, 98 and the
# action tables in t/unit/lib/16) have no copies left to compare; what can still
# be wrong is the declaration itself. So this asks, of every entry, that it says
# what an entry must say and says it in a shape the derivations read correctly.
# A misspelt FIELD is refused at load already; this covers the values. Adding an
# action is one entry, its handler and its test - and this holds the entry to
# the shape.
subtest 'SM943 stage 3: every action declaration is complete' => sub {
    require Lazysite::Capabilities;
    my %CAP   = map { $_ => 1 } Lazysite::Capabilities::capability_keys();
    my %IN    = map { $_ => 1 } qw(query body query_or_body);
    my %PKEY  = map { $_ => 1 } qw(name in required note);
    my @FLAGS = qw(mutates destructive changes_access scoped mcp_open_world);
    my $mcp   = do {
        open my $fh, '<', repo_root() . '/lazysite-mcp.pl' or die $!;
        local $/;
        <$fh>;
    };
    my ($tools) = $mcp =~ /\nmy %TOOLS = \((.*?)\n\);\n/s;
    my %TOOL = map { $_ => 1 } ( $tools // '' ) =~ /^    ([a-z_]+) => \{\n/mg;
    cmp_ok( scalar keys %TOOL, '>=', 60, 'the MCP tool table was read' );

    my $decl = \%Lazysite::ControlApi::Actions::ACTION;
    cmp_ok( scalar keys %$decl, '>=', 100, 'the declaration was read' );
    my @bad;
    for my $name ( sort keys %$decl ) {
        my $s = $decl->{$name};
        push @bad, "$name: the name is not an action name" unless $name =~ /\A[a-z][a-z0-9_-]*\z/;

        # params: REQUIRED, the one field with no default - the reference and the
        # missing-parameter check (SM773) both read it.
        if ( ref $s->{params} ne 'ARRAY' ) { push @bad, "$name: no params list"; }
        else {
            my %seen;
            for my $p ( @{ $s->{params} } ) {
                my $pn = ref $p eq 'HASH' ? $p->{name} // '' : '';
                push @bad, "$name: a parameter with no name" unless $pn =~ /\A[a-z_]+\z/;
                push @bad, "$name: '$pn' is listed twice" if $seen{$pn}++;
                push @bad, "$name: '$pn' is read from '" . ( $p->{in} // '' ) . "'"
                    unless $IN{ $p->{in} // '' };
                push @bad, "$name: '$pn' marks required as '$p->{required}'"
                    if exists $p->{required} && $p->{required} ne '1';
                push @bad, "$name: '$pn' has an empty note"
                    if exists $p->{note} && !length( $p->{note} // '' );
                push @bad, "$name: '$pn' declares '$_', which a parameter does not have"
                    for grep { !$PKEY{$_} } sort keys %$p;
            }
        }

        # A flag is written only where it is true; a written 0 reads as a
        # decision and means the default.
        for my $f (@FLAGS) {
            push @bad, "$name: $f is written as '$s->{$f}'"
                if exists $s->{$f} && $s->{$f} ne '1';
        }
        # `audited` states an EXCEPTION to "audited exactly when it mutates";
        # one that restates the default is noise that hides the real exceptions.
        if ( exists $s->{audited} ) {
            push @bad, "$name: audited is '$s->{audited}'" unless $s->{audited} =~ /\A[01]\z/;
            push @bad, "$name: audited => $s->{audited} only restates the default"
                if $s->{audited} eq ( $s->{mutates} ? '1' : '0' );
        }
        for my $f (qw(cookie_gates_itself cookie_only_reason)) {
            push @bad, "$name: $f gives no reason"
                if exists $s->{$f} && length( $s->{$f} // '' ) < 20;
        }
        if ( defined( my $cc = $s->{cookie_cap} ) ) {
            push @bad, "$name: cookie_cap '$cc' names a capability that does not exist"
                for grep { !$CAP{$_} } split /[|+]/, $cc;
        }
        if ( defined $s->{caps} ) {
            push @bad, "$name: the gate names '$_', which is not a capability"
                for grep { !$CAP{$_} } @{ $s->{caps} };
        }

        # The MCP twin: a tool that exists. Its hints are derived, so nothing else
        # about it can disagree.
        if ( defined( my $t = $s->{mcp} ) ) {
            push @bad, "$name: its MCP twin '$t' is not a tool in lazysite-mcp.pl"
                unless $TOOL{$t};
        }
    }
    is_deeply( \@bad, [], 'every action declares params, and every field it writes is well formed' )
        or diag( join "\n  ", '', @bad );
};

done_testing();
