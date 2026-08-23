---
title: "Four checks on the site manager"
subtitle: "A guided walk through four things that must work when a person clicks them. About 20 minutes. No technical knowledge needed - if you can sign in, you can do all of this."
brand: plain
---

# Before you start

You will be told the site address and given a sign-in. Sign in, and keep two
browser windows open throughout:

your manager window
: the one you signed into - this is where you do things

a private window
: open a new private/incognito window and leave yourself signed OUT there -
  this is how you check what an ordinary visitor sees

You also need one folder of pages you do not mind hiding for a minute. If
nobody has pointed one out, ask - or make a folder with two or three pages in
it first.

::: widebox
For each numbered task, do the steps in order and compare what you see with
the *You should see* line. At the end of each task, write down **PASS** or
**FAIL** - and if anything looked different from what this sheet says,
describe what you actually saw in a sentence or two. A detailed "it did
something odd" is far more useful than a bare fail.
:::

If a task tells you to skip in some situation, skipping is fine - just write
**SKIPPED** and the reason. Never guess a result.

# Task 1 - hide a folder, then publish it

1. In your manager window, go to **Files**.
2. Find your test folder in the list. At the right-hand end of its row, click
   the small **&#9662;** arrow. A card opens underneath it.
3. In that card, under **Protect this section**, choose **Draft**.
4. Leave *Who may read it* empty.
5. Click **Protect this section**, and confirm.

   *You should see:* a message saying the section is hidden. Further down the
   Files page, a card called **Protected sections** now lists your folder with
   a **draft** label and a count of what is inside it.

6. In your private window, try to visit the folder's page on the site -
   the address is the site name followed by the folder name, for example
   `https://the-site/your-folder/`.

   *You should see:* a **page not found** error. Not a sign-in prompt - the
   page should simply appear not to exist.

7. Back in your manager window, on the **Protected sections** card, click
   **Publish** on your folder's row, and confirm.

   *You should see:* the label change from **draft** to **gated**, and the row
   stay in the list. Reload the private window: the page now loads normally.

Write down: PASS or FAIL. It is a FAIL if the row never appeared, if Publish
did not change the label, if the page still shows not-found in the private
window after publishing, or if the row disappeared from the list when you
clicked Publish.

# Task 2 - remove the protection completely

1. On that same **Protected sections** row (now labelled **gated**), click
   **Remove protection**.
2. Read the confirmation message before accepting it.

   *You should see:* wording that makes clear this is a bigger step than
   Publish was - it removes the reader list too, so the folder stops being
   protected at all. If the message reads exactly like the Publish one did,
   that is worth noting.

3. Accept.

   *You should see:* the row disappear from the card entirely. The folder is
   ordinary, visible content again - check it loads in the private window.

Write down: PASS or FAIL. It is a FAIL if the confirmation was
indistinguishable from Publish's, if the row stayed after accepting, or if the
folder was still blocked afterwards.

# Task 3 - copy a site across, then undo it

This task needs the site to have a second web address (a second domain) set
up with its own pages. If you have not been told there is one, write
**SKIPPED - no second domain** and move on.

1. Go to **Backups**. If nothing is listed under site packages, first go to
   **Domains** and click **Export site** for any domain, then come back.
2. On a package row, click **Apply**. A panel opens.
3. In **Apply to**, choose the second domain.

   *You should see:* a summary appear saying how many files are new and how
   many would be **overwritten**. Note the overwritten number.

4. Change **Apply to** to a different choice, then change it back.

   *You should see:* the numbers **change** when the target changes. If the
   numbers stay exactly the same whatever you pick, note that - it matters.

5. Click **Apply package** and confirm.

   *You should see:* a success message, and a bar appear at the top of the
   page offering **Undo - restore ...**.

6. In your private window, visit the second domain: its pages should now be
   the copied site's pages.
7. Back in the manager, click **Undo** in that top bar, and confirm.

   *You should see:* a restore run. Visit the second domain again in the
   private window - it is back to what it was before step 5.

Write down: PASS or FAIL (or SKIPPED). It is a FAIL if the overwritten number
never changed with the target, if the Undo bar never appeared, or if Undo did
not put the second domain back the way it was.

# Task 4 - naming a person works the same way everywhere

This one is about the small picker used to choose a person or a group. You
will meet it in four places, and in every one of them it must be a proper
drop-down list - never a plain box you can type any spelling into.

1. Go to **Files**, open your test folder's card again, and look at the picker
   beside *Who may read it* under **Protect this section**.

   *You should see:* a drop-down of real user names and group names (groups
   start with `@`). Choosing one adds it as a small removable tag. There is no
   way to enter a name that does not exist.

2. Add two names, remove one of them with its **&times;**, then click
   **Protect this section**. Re-open the card.

   *You should see:* the reader list showing exactly the one name you left -
   the removed one is gone, nothing extra appeared.

   Afterwards, remove the protection again (as in Task 2) so the folder is
   left the way you found it.

3. Go to **Groups**, open any group, and try the *add a user or group* picker.

   *You should see:* a drop-down, and the group you have open should NOT be
   offered as an addition to itself. Now try moving through the options with
   the keyboard arrow keys: nothing should be added while you arrow around -
   only the **Add** button adds the name you settled on.

4. Go to **Users**, start the add-user form, and try its *add a group*
   picker. Then go to **Domains**, open a domain's settings, and try the two
   pickers there - *Groups allowed to manage* and *Users locked to this
   domain*.

   *You should see:* proper drop-downs everywhere. On the Domains page, the
   groups field should offer only groups, and the users field only users.

Write down: PASS or FAIL. It is a FAIL if any of these pickers is a plain
text box or accepts a typed name that does not exist; if arrowing through the
Groups list added someone without you pressing Add; if a tag could not be
removed; or if the saved reader list in step 2 did not match what you chose.

# Task 5 - a table, from nothing to a spreadsheet and back

You need the **Data tables** plugin switched on (Plugin Manager), and your
account in a group that holds **Data**.

1. In your manager window, go to **Data tables**.

   *You should see:* a list of tables, or the words *No tables are declared
   yet*. If instead you see *The data plugin is disabled*, switch it on and
   come back - that message is the plugin doing its job.

2. Declare a small table through the API or an agent - `describe_data_table`'s
   own text shows the shape. Three fields is enough: a text key, an integer
   with a default, and a date. Do **not** add `public: true`. Press
   **Refresh**.

   *You should see:* your table listed as **not published** and **needs
   migrating**. Both are the expected state of a new table.

3. Click **Fields** on its row.

   *You should see:* the descriptor, exactly as it was written - comments,
   spacing, and the order you put the keys in. Click **What would migrating
   do?**

   *You should see:* *The stored table does not exist yet. Migrate creates
   it.* Click **Migrate**, then **Refresh**. *needs migrating* should be gone.

4. Click **Rows**, then **Add a row**. Fill in the key, leave the integer
   blank, type a word into the date, and **Save**.

   *You should see:* the save refused, the date input **outlined and
   focused**, and the server's own sentence about what a date looks like.
   Fix the date and save again. The row appears; the integer shows its
   default, which you never typed.

   It is a FAIL if the message appeared but no input was outlined.

5. Click **Edit** on that row.

   *You should see:* the key field **greyed and read-only**. Change the
   integer, save, reload the page, open the row again: the change persisted
   and the key did not move.

6. Click **CSV** to download the table. Open it in a spreadsheet, change the
   integer on your row, add a second row, and save it back as CSV. Click
   **Import CSV...** and choose the file.

   *You should see:* a plan - *2 rows - 1 new, 1 updating existing rows by
   key. Nothing has been written yet.* - and nothing changed in the grid
   behind it. Click **Apply**. Now both rows are there.

7. Put a word into the integer column of that file, import it again.

   *You should see:* the whole file refused, the message naming the **row as
   your spreadsheet numbers it** and the field, and nothing in the grid
   changed - not the good row either.

8. Click **Fields** again. Make the date field `required: true` while your
   second row has no date. **Save descriptor**, then **What would migrating
   do?**

   *You should see:* Migrate will refuse the tightening, and underneath: *A
   rebuild would fail on the existing rows. Fix these first: 1 row has no
   'when'* - naming the count. There is **no rebuild button**. Fill in that
   row's date, plan again: now the rebuild button appears and says which
   columns it would drop (none, this time).

   It is a FAIL if a rebuild button was offered while a row still lacked the
   date.

9. Click **Fields**, remove the integer field entirely, save, plan, and click
   **Rebuild**.

   *You should see:* a prompt that **names the column** and asks you to type
   it. Type something else first: refused. Type the name: the rebuild runs and
   reports the safety export as a path **inside the site**, starting
   `lazysite/`, never `/home/` or `/var/`.

10. Back on the list, click **JSON** on your table, and then use
    `drop_data_table` (or `data-table-drop`) naming the table in `confirm`.

    *You should see:* the JSON file contain your rows with the date as text
    and the integer as a number; and after the drop, the table gone from the
    list and a safety export path returned, again inside the site.

Write down: PASS or FAIL, and **which step** you stopped at if not all ten.
It is a FAIL if any *You should see* did not happen; it is a PASS only if all
ten did.

# When you are done

Send back the four results with your notes, and say which site and which day
you did the walk on. If anything surprised you - even something not covered by
a FAIL condition above - write it down too. Things a checklist did not
anticipate are often the most valuable finds.
