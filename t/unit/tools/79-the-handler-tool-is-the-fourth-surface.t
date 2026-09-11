#!/usr/bin/perl
# SM842: the shell surface of the handler contract, and the upgrade's converter.
#
# tools/lazysite-handlers.pl calls the same Lazysite::Handlers functions as the
# manager, the control API and MCP. A write needs --actor, on SM289's argument:
# there is no session behind a shell, and an unconstrained default would make
# this the one surface where the destination does not decide. `convert` needs
# none - it widens nothing - and is what install.pl runs on an upgrade, from the
# installed tree, as a separate process (the installer must not load the lib).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir run_cmd add_account grant_caps);

my $root = repo_root();
my $tool = "$root/tools/lazysite-handlers.pl";

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

my $d = site_tempdir();
make_path( "$d/lazysite/forms", "$d/lazysite/auth", "$d/lazysite/logs", "$d/lazysite/connectors" );
spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );

sub tool { my @a = @_; my $out = run_cmd( $^X, $tool, @a, '--docroot', $d ); return ( $? >> 8, $out ) }

subtest 'a write needs an actor, and gets exactly that actor\'s authority' => sub {
    my ( $rc, $out ) = tool( 'save', 'store', '--set', 'type=file', '--set', 'name=Store' );
    is( $rc, 2, 'no --actor: refused' );
    like( $out, qr/--actor is required for a write/, 'saying why' );

    add_account( $d, 'editor' );
    grant_caps( $d, 'editor', qw(manage_forms) );
    ( $rc, $out ) = tool( 'save', 'rows', '--set', 'type=table', '--set', 'name=R', '--set', 'table=t',
        '--set', 'fields=a=b', '--actor', 'editor' );
    is( $rc, 1, 'an actor without manage_data cannot make a table handler from a shell either' );
    like( $out, qr/manage_data/, 'and is told which capability it lacks' );

    ( $rc, $out ) = tool( 'save', 'store', '--set', 'type=file', '--set', 'name=Store', '--actor', 'editor' );
    is( $rc, 0, 'a file handler is within manage_forms' ) or diag $out;
    ( $rc, $out ) = tool( 'bind', 'contact', 'store', '--actor', 'editor' );
    is( $rc, 0, 'and so is binding a form to it' ) or diag $out;
    like( slurp("$d/lazysite/forms/contact.conf"), qr/- handler: store/, 'which the form config now says' );

    ( $rc, $out ) = tool('list');
    like( $out, qr/^store\s+file\s+on\s+Store\s+\[form:contact\]/m, 'list shows the handler and its user' );
};

subtest 'convert: says what it did, exits 1 when something is left, 0 when nothing is' => sub {
    spit( "$d/lazysite/forms/handlers.conf",
        "handlers:\n  - id: store\n    type: file\n    name: Store\n"
            . "  - id: rows\n    type: db\n    name: R\n    table: t\n    fields: a=b\n"
            . "  - id: plain\n    type: webhook\n    name: P\n    url: http://intranet.example/h\n" );
    my ( $rc, $out ) = tool( 'convert', '--dry-run' );
    like( $out, qr/would convert - handler 'rows': db -> table/, 'a dry run says what it would do' );
    like( slurp("$d/lazysite/forms/handlers.conf"), qr/type: db/, 'and does not do it' );

    ( $rc, $out ) = tool('convert');
    is( $rc, 1, 'something could not be converted: exit 1' );
    like( $out, qr/converted - handler 'rows': db -> table/, 'what it converted' );
    like( $out, qr/NOT converted - handler 'plain'/, 'and what it could not, with the reason' );

    spit( "$d/lazysite/forms/handlers.conf",
        "handlers:\n  - id: store\n    type: file\n    name: Store\n" );
    ( $rc, $out ) = tool('convert');
    is( $rc, 0, 'a site already in shape: exit 0' );
    like( $out, qr/nothing to convert/, 'and it says so' );
};

subtest 'lazysite-check says when a shape survived the upgrade' => sub {
    spit( "$d/lazysite/forms/handlers.conf",
        "handlers:\n  - id: store\n    type: file\n    name: Store\n  - id: hook\n    name: H\n    type: webhook\n" );
    spit( "$d/lazysite/forms/old.conf", "targets:\n  - type: file\n" );
    my $out = run_cmd( $^X, "$root/tools/lazysite-check.pl", '--docroot', $d );
    like( $out, qr/warn \] 2 delivery setting\(s\) the engine no longer reads: [^\n]*handler 'hook' is a 'webhook' handler/,
        'a webhook handler is reported' );
    like( $out, qr/form 'old' has an inline target/, 'and an inline form target' );
    like( $out, qr/lazysite-handlers\.pl convert --docroot/, 'with the command that repairs it' );
    unlike( $out, qr/handler 'store'/, 'and nothing about a handler that is fine' );

    unlink "$d/lazysite/forms/old.conf";
    spit( "$d/lazysite/forms/handlers.conf", "handlers:\n  - id: store\n    type: file\n    name: Store\n" );
    $out = run_cmd( $^X, "$root/tools/lazysite-check.pl", '--docroot', $d );
    like( $out, qr/every form and schedule names a handler the engine reads/, 'a clean site is said to be clean' );
};

subtest 'the fleet form: options ahead of the command' => sub {
    # `lazysite handlers --all convert` runs the tool per site as
    # `--docroot D --cgibin C convert`; the command is not the first word.
    my $out = run_cmd( $^X, $tool, '--docroot', $d, '--cgibin', '/nowhere', 'convert' );
    is( $? >> 8, 0, 'the command is found after the options' ) or diag $out;
    like( $out, qr/nothing to convert/, 'and runs' );
    my $cli = slurp("$root/tools/lazysite-cli.pl");
    like( $cli, qr/run_tool_per_site\( 'tools\/lazysite-handlers\.pl'/, 'which the lazysite command does' );
};

subtest 'it will not write a site tree as root' => sub {
    local $ENV{LAZYSITE_CLI_FAKE_ROOT} = 1;
    my ( $rc, $out ) = tool('convert');
    is( $rc, 2, 'refused' );
    like( $out, qr/refusing to write as root/, 'saying why' );
    ( $rc, $out ) = tool('list');
    is( $rc, 0, 'while a read is fine' );
};

subtest 'the installer runs it on an upgrade, from the installed tree' => sub {
    my $inst = slurp("$root/install.pl");
    like( $inst, qr/if \( \$mode ne 'fresh' \) \{\s*my \( \$ok, \$why \) = run_handler_conversion\(/,
        'on every upgrade or reinstall' );
    like( $inst, qr/\{DOCROOT\}\/\.\.\/tools\/lazysite-handlers\.pl/, 'the INSTALLED tool' );
    like( $inst, qr/exec\( \$\^X, \$tool, 'convert'/, 'as its own process' );
    unlike( $inst, qr/^\s*(?:use|require)\s+Lazysite::/m,
        'and the installer itself still loads no Lazysite module (SM767)' );
    like( $inst, qr/HANDLERS: the SM842 conversion did not finish cleanly/,
        'a conversion that leaves something is a warning in the upgrade summary' );
};

done_testing();
