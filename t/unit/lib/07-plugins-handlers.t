#!/usr/bin/perl
# SM079a coverage: in-process tests for Manager::Plugins action handlers.
# Verifies the conf mutations and round-trip fidelity, not just that the
# handlers ran, and pins the specific refusal reasons.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Plugins qw(
    action_plugin_enable action_plugin_disable action_handler_save
    action_handler_list action_handler_delete action_form_targets_save
    action_form_targets_read action_form_submissions action_form_submission_delete
    action_form_list action_form_submission_confirm action_form_submissions_delete_bulk
    resolve_plugin_script);

# SM152: a real install layout - base holds plugins/, docroot is base/public_html
# - so the plugin registry (base/plugins/*.pl + core) resolves. enable/disable
# and resolve now go through that registry, not an arbitrary path.
my $base = tempdir( CLEANUP => 1 );
my $d    = "$base/public_html";
make_path( "$d/lazysite/forms", "$d/lazysite/cache", "$base/plugins" );
for my $p (qw(log.pl audit.pl)) {
    open my $pf, '>', "$base/plugins/$p" or die $!;
    print {$pf} "print '{\"id\":\"$p\",\"actions\":[]}' if \"@ARGV\"=~/--describe/; exit 0;\n";
    close $pf;
}
$Lazysite::Manager::Plugins::DOCROOT = $d;
$Lazysite::Manager::Plugins::action  = 'test';
open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$c} "site_name: T\n";
close $c;

sub slurp_conf { open my $f, '<', "$d/lazysite/lazysite.conf"; local $/; <$f> }
sub handler_by_id {
    my ($id) = @_;
    my $hl = action_handler_list();
    return undef unless $hl->{ok};
    return ( grep { ( $_->{id} // '' ) eq $id } @{ $hl->{handlers} || [] } )[0];
}

# --- plugin enable / disable mutate the conf correctly ---
ok( action_plugin_enable('plugins/log.pl')->{ok},   'enable a plugin' );
like( slurp_conf(), qr{plugins:\s*\n\s+- plugins/log\.pl}s, 'plugin added under a plugins: block' );
ok( action_plugin_enable('plugins/audit.pl')->{ok}, 'enable a second' );
like( slurp_conf(), qr{audit\.pl}, 'second plugin present' );
ok( action_plugin_disable('plugins/log.pl')->{ok},  'disable a plugin' );
unlike( slurp_conf(), qr{log\.pl},  'disabled plugin removed' );
like( slurp_conf(), qr{audit\.pl},  'the other plugin survives the disable' );
my $bad = action_plugin_enable('');
ok( !$bad->{ok}, 'empty script rejected' );
like( $bad->{error}, qr/no script/i, 'with a "No script" error' );

# --- handler config round-trips its fields ---
my $hs = action_handler_save(
    { id => 'email1', type => 'smtp', name => 'Email', to => 'ops@example.com' } );
ok( $hs->{ok}, 'handler saved' );
my $h = handler_by_id('email1');
ok( $h, 'saved handler is listed' );
is( $h->{type}, 'smtp',            'handler type round-trips' );
is( $h->{to},   'ops@example.com', 'handler to-address round-trips' );
ok( action_handler_delete('email1')->{ok}, 'handler deleted' );
ok( !handler_by_id('email1'), 'deleted handler no longer listed' );
my $hbad = action_handler_save( { id => '' } );
ok( !$hbad->{ok}, 'handler with no id rejected' );
like( $hbad->{error}, qr/handler id/i, 'with an "Invalid handler ID" error' );

# --- form targets: clean single-format round-trips ---
ok( action_form_targets_save( 'contact', [ { handler => 'email1' }, { handler => 'local-storage' } ] )->{ok},
    'handler-format targets saved' );
is_deeply( action_form_targets_read('contact')->{targets},
    [ { handler => 'email1' }, { handler => 'local-storage' } ],
    'all-handler targets round-trip exactly' );

ok( action_form_targets_save( 'legacy', [ { type => 'file', path => 'submissions' } ] )->{ok},
    'legacy type-format targets saved' );
is_deeply( action_form_targets_read('legacy')->{targets},
    [ { type => 'file', path => 'submissions' } ],
    'all-type targets round-trip exactly' );

# SM081 (fixed): a form mixing handler: + type: now round-trips BOTH targets in
# document order (the read used to drop the type targets if any handler existed).
action_form_targets_save( 'mixed', [ { handler => 'email1' }, { type => 'file' } ] );
is_deeply( action_form_targets_read('mixed')->{targets},
    [ { handler => 'email1' }, { type => 'file' } ],
    'SM081 fixed: mixed-format read preserves both targets in order' );

# DATA-LOSS GUARD: the manager "Edit targets" UI only knows HANDLER targets. When
# it re-saves a form that has a legacy inline target, it sends only the handlers -
# the inline target must NOT be erased (it was, before this fix).
{
    # A form authored (by hand / WebDAV) with a handler AND an inline target.
    open my $fc, '>', "$d/lazysite/forms/legacymix.conf" or die $!;
    print $fc "targets:\n  - handler: email1\n  - type: webhook\n    url: https://hook.example/x\n";
    close $fc;
    # The UI re-saves sending ONLY the handler set (its view of the world).
    ok( action_form_targets_save( 'legacymix', [ { handler => 'email1' } ] )->{ok},
        'save with only the handler succeeds' );
    is_deeply( action_form_targets_read('legacymix')->{targets},
        [ { handler => 'email1' }, { type => 'webhook', url => 'https://hook.example/x' } ],
        'the legacy inline target is PRESERVED (not erased by a handler-only UI save)' );

    # But a submission that DOES carry inline targets replaces wholesale (a future
    # UI that manages them) - no duplication of the preserved set.
    action_form_targets_save( 'legacymix',
        [ { handler => 'email1' }, { type => 'file', path => 'submissions' } ] );
    is_deeply( action_form_targets_read('legacymix')->{targets},
        [ { handler => 'email1' }, { type => 'file', path => 'submissions' } ],
        'a submission carrying inline targets replaces wholesale (no double-write)' );
}

# --- resolve_plugin_script (SM152: registry-only) ---
is( resolve_plugin_script('plugins/log.pl'), "$base/plugins/log.pl",
    'a registered plugin resolves to its canonical path' );
ok( !defined resolve_plugin_script('does-not-exist.pl'),
    'an unregistered name resolves to undef' );
# A script placed beside the docroot is NOT a registry key -> no longer resolves
# (this was the RCE: arbitrary path resolution). See 27-plugin-registry-rce.t.
open my $p, '>', "$base/sample-plugin.pl" or die $!;
print {$p} "1;\n"; close $p;
ok( !defined resolve_plugin_script('sample-plugin.pl'),
    'a script beside the install root is NOT resolvable (registry-only)' );
ok( !defined resolve_plugin_script('../sample-plugin.pl'),
    'a traversal path is NOT resolvable' );
unlink "$base/sample-plugin.pl";

# --- SM182: read a submissions store as a structured table -------------------
{
    make_path("$d/lazysite/forms/submissions");
    my $sub = "$d/lazysite/forms/submissions/contact.jsonl";
    open my $sf, '>', $sub or die $!;
    # Mixed keys, a nested value, an XSS-y value (must survive verbatim for the
    # client to escape), a blank line, and a malformed line.
    print $sf qq({"ts":"2026-07-19","name":"Jo","msg":"hi"}\n);
    print $sf qq({"ts":"2026-07-19","name":"<script>x</script>","tags":["a","b"]}\n);
    print $sf qq(\n);
    print $sf qq(not json\n);
    close $sf;

    my $r = action_form_submissions('lazysite/forms/submissions/contact.jsonl');
    ok( $r->{ok}, 'form-submissions reads the store' );
    is( $r->{total},     3, 'counts non-blank records (incl. the malformed one)' );
    is( $r->{malformed}, 1, 'reports the malformed line' );
    is( $r->{shown},     2, 'returns the 2 parseable rows' );
    is_deeply( [ sort @{ $r->{columns} } ], [qw(msg name tags ts)],
        'columns are the union of all record keys' );
    is( $r->{rows}[1]{name}, '<script>x</script>',
        'a hostile value is returned VERBATIM (server does not escape; the client does)' );
    is( $r->{rows}[1]{tags}, '["a","b"]', 'a nested value is JSON-stringified' );

    # Path confinement: traversal + non-.jsonl are refused.
    ok( !action_form_submissions('lazysite/forms/submissions/../../auth/.secret')->{ok},
        'a traversal path is refused' );
    ok( !action_form_submissions('lazysite/forms/submissions/contact.txt')->{ok},
        'a non-.jsonl path is refused' );

    # A missing file is an empty table, not an error (form with no submissions).
    my $empty = action_form_submissions('lazysite/forms/submissions/none.jsonl');
    ok( $empty->{ok} && $empty->{total} == 0, 'a form with no submissions yields an empty table' );

    # SM187: every row carries a stable _id (raw-line hash) for deletion.
    like( $r->{rows}[0]{_id}, qr/\A[0-9a-f]{16}\z/, 'each row has a stable 16-hex _id' );
    isnt( $r->{rows}[0]{_id}, $r->{rows}[1]{_id}, 'distinct rows get distinct ids' );

    # SM187: delete one handled row by its _id; the store shrinks by exactly one.
    my $del = action_form_submission_delete(
        'lazysite/forms/submissions/contact.jsonl', $r->{rows}[0]{_id} );
    ok( $del->{ok} && $del->{deleted}, 'delete removes the identified row' );
    my $after = action_form_submissions('lazysite/forms/submissions/contact.jsonl');
    is( $after->{shown}, 1, 'one parseable row remains after the delete' );
    is( $after->{rows}[0]{_id}, $r->{rows}[1]{_id}, 'the OTHER row survived (right one deleted)' );

    # A bad / unknown id and a traversal are refused.
    ok( !action_form_submission_delete('lazysite/forms/submissions/contact.jsonl', 'nope')->{ok},
        'a malformed row id is refused' );
    ok( !action_form_submission_delete('lazysite/forms/submissions/contact.jsonl', '0' x 16)->{ok},
        'an unknown row id is a not-found, not a silent success' );
    ok( !action_form_submission_delete('lazysite/forms/submissions/../../auth/.secret', '0' x 16)->{ok},
        'delete refuses a traversal path' );
}

# --- SM214: form-list (PII-free form discovery for token clients) ------------
{
    action_handler_save( { id => 'local-storage', type => 'file', name => 'Local' } );
    open my $fc, '>', "$d/lazysite/forms/feedback.conf" or die $!;
    print {$fc} "targets:\n  - handler: local-storage\n";
    close $fc;
    make_path("$d/lazysite/forms/submissions");
    open my $st, '>', "$d/lazysite/forms/submissions/feedback.jsonl" or die $!;
    print {$st} qq({"name":"alice"}\n{"name":"bob"}\n);
    close $st;

    my $fl = action_form_list();
    ok( $fl->{ok}, 'form-list ok' );
    my ($fb) = grep { $_->{name} eq 'feedback' } @{ $fl->{forms} };
    ok( $fb, 'the feedback form is listed' );
    is_deeply( $fb->{handler_types}, ['file'], 'handler type resolved from handlers.conf (file)' );
    ok( $fb->{has_store}, 'the submissions store is detected' );
    is( $fb->{rows}, 2, 'row count is correct' );
    ok( !( grep { $_->{name} eq 'handlers' || $_->{name} eq 'smtp' } @{ $fl->{forms} } ),
        'handlers.conf / smtp.conf are not listed as forms' );
    is_deeply(
        [ sort keys %$fb ],
        [ sort qw(name handlers handler_types has_store rows row_count) ],
        'a form entry carries only names + counts - no submission content (PII-free)' );

    # SM227: `rows` means a COUNT here and an ARRAY OF ROWS in
    # action_form_submissions. row_count is the unambiguous spelling; rows stays
    # one release as a deprecated alias, so they must agree.
    is( $fb->{row_count}, 2, 'row_count is the submission count' );
    is( $fb->{row_count}, $fb->{rows}, 'the deprecated rows alias agrees with it' );
    like( $fl->{note}, qr/read_form_submissions/,
        'the response names the companion action' );
    like( $fl->{note}, qr/read_submissions/,
        'and the capability that unlocks it' );
}

# --- SM216: confirm (un-quarantine) a flagged row - keeps it, clears the flag -
{
    my $qf = "$d/lazysite/forms/submissions/quar.jsonl";
    open my $sf, '>', $qf or die $!;
    print $sf qq({"ts":"2026-07-26","name":"Real","msg":"hello"}\n);
    print $sf
        qq({"ts":"2026-07-26","name":"Spam","msg":"buy https://a https://b","_quarantined":true,"_spam_reason":"2 urls"}\n);
    close $sf;

    my $r = action_form_submissions('lazysite/forms/submissions/quar.jsonl');
    my ($qrow) = grep { $_->{_quarantined} } @{ $r->{rows} };
    ok( $qrow, 'the quarantined row is surfaced carrying its flag' );

    my $ok = action_form_submission_confirm(
        'lazysite/forms/submissions/quar.jsonl', $qrow->{_id} );
    ok( $ok->{ok} && $ok->{confirmed}, 'confirm reports success' );

    my $after = action_form_submissions('lazysite/forms/submissions/quar.jsonl');
    is( $after->{total}, 2, 'confirm keeps the row - store size unchanged' );
    my @still = grep { $_->{_quarantined} } @{ $after->{rows} };
    is( scalar @still, 0, 'no row remains quarantined after the confirm' );

    ok( !action_form_submission_confirm( 'lazysite/forms/submissions/quar.jsonl', '0' x 16 )->{ok},
        'confirm of an unknown id is a not-found, not a silent success' );
    ok( !action_form_submission_confirm( 'lazysite/forms/submissions/../../auth/.secret', '0' x 16 )->{ok},
        'confirm refuses a traversal path' );
}

# --- SM187: bulk delete - drop several rows in one atomic rewrite ------------
{
    my $bf = "$d/lazysite/forms/submissions/bulk.jsonl";
    open my $sf, '>', $bf or die $!;
    print $sf qq({"name":"a","msg":"1"}\n);
    print $sf qq({"name":"b","msg":"2"}\n);
    print $sf qq({"name":"c","msg":"3"}\n);
    close $sf;

    my $r   = action_form_submissions('lazysite/forms/submissions/bulk.jsonl');
    my @ids = map { $_->{_id} } @{ $r->{rows} };
    is( scalar @ids, 3, 'three rows to start' );

    # delete the first and third by id; the middle survives.
    my $del = action_form_submissions_delete_bulk(
        'lazysite/forms/submissions/bulk.jsonl', [ $ids[0], $ids[2] ] );
    ok( $del->{ok} && $del->{deleted} == 2, 'bulk delete removes exactly the two selected rows' );
    my $after = action_form_submissions('lazysite/forms/submissions/bulk.jsonl');
    is( $after->{total}, 1, 'one row remains' );
    is( $after->{rows}[0]{_id}, $ids[1], 'the unselected middle row is the survivor' );

    ok( !action_form_submissions_delete_bulk( 'lazysite/forms/submissions/bulk.jsonl', [] )->{ok},
        'an empty id list is refused, not a silent no-op success' );
    ok( !action_form_submissions_delete_bulk( 'lazysite/forms/submissions/bulk.jsonl', ['nope'] )->{ok},
        'a malformed id in the batch is refused' );
    ok( !action_form_submissions_delete_bulk(
            'lazysite/forms/submissions/../../auth/.secret', [ '0' x 16 ] )->{ok},
        'bulk delete refuses a traversal path' );
    ok( !action_form_submissions_delete_bulk(
            'lazysite/forms/submissions/bulk.jsonl', [ '0' x 16 ] )->{ok},
        'a batch matching no rows is a clean not-found' );
}

done_testing();
