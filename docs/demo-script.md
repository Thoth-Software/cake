# Demo script

For whoever presents Cake, or hands it to a tester. It is the path the front end was walked on before it was called done: thirteen steps, in a real browser, against a real search node and the real provider, at desktop and phone width and in both themes.

It takes about ten minutes. The only waiting is the upload (a short PDF ingests in a few seconds, a long one in minutes) and each answer (a few seconds).

## Before you start

- **A PDF with real text in it.** Not a scan: see "What a tester will run into" below. Pick one you can ask a pointed question about, with an answer you know and can find on a page.
- **A first admin.** No screen creates one; `docs/runbooks/first-admin.md` has the command. A dev database has one already if the seed has been run on it (`mix ecto.setup` runs it, and so does the dev container on every boot).
- **Two browser windows**, one of them private, if you want to show steps 12 and 13: the admin acts in one and the member's open page reacts in the other.
- **The theme.** The top bar's toggle switches between following the system, light and dark. Pick before you start; it is remembered per browser.

## The walk

| # | Do | What to point at |
|---|---|---|
| 1 | Open the home page. | The product name, one sentence and a log-in button. Nobody is logged in, so the top bar offers only Register and Log in. |
| 2 | Log in as the admin. Open **Admin**, then **Manage logins**, then **New login**. Type a username, an email and a password, leave the role at Member, and save. | Log-in lands on the chat. The new login is in the list at once, marked Confirmed: a login an admin makes works straight away, and nothing is mailed to the address. |
| 3 | Open the menu under your username and log out. Log in as the member. | The member's top bar has Chat, Documents, Upload and Search, and no Admin. |
| 4 | Type `/admin` into the address bar. | The member is sent back to the chat and told they are not authorized. The link was not merely hidden. |
| 5 | Open **Upload**. Drag the PDF onto the drop zone, then press **Upload and ingest**. | The queue shows the file, its size and its progress. While it ingests the page says to keep the tab open. It ends in "Ingestion complete" with the number of sections indexed. On a phone there is nothing to drag: the drop zone is a **Choose files** button. |
| 6 | Follow **See the documents**. Open the document. | The list has the title, the page count, a Completed badge, the upload time and a download link. The document's page adds the word count and the number of chunks. |
| 7 | Open **Chat** and ask your pointed question. Hover a source chip under the answer (on a phone, tap it). Press the chip's arrow. | The answer carries `[1]`-style markers, and the chips under it carry the same numbers, each with its title and page. The chip's label opens a preview of the passage; its arrow downloads the file that was uploaded, byte for byte. A warning notice under an answer, "Check this answer against its sources", means the model referred to a source that was not retrieved: the reference has been removed from the text, and the notice says how many such sources there were. |
| 8 | Ask a follow-up that only makes sense after the first question ("And what happens if…?"). | It is answered in context, and cites again. |
| 9 | Switch on **Manual selection** and ask the first question again. Tick the document and press **Use selected**. | Before anything is written, the documents the search found are shown as cards, each with its pages and a preview. The answer uses only what was ticked. |
| 10 | Open **Search** and type a phrase you know is in the document. | The document comes back as a card with a chip per matching page; a chip shows the start of its passage. This is the retrieval on its own, with no answer written. |
| 11 | Open the menu under the username, choose **Change password**, and change it. | The member stays logged in. The old password no longer works; the new one does. |
| 12 | In the other window, as the admin: open the member's login, **Set password**, save. Look at the member's window. | The member's open page goes to the log-in page by itself, saying the session has ended. Only the password the admin set works now. |
| 13 | As the admin, delete the member's login from the list. | The row goes. A page the member had open is logged out the same way, and the login is refused. |

Steps 5 to 10 are the product. Steps 1 to 4 and 11 to 13 are how a tester gets a login and loses it; skip them for an audience that only wants to see answers.

## What a tester will run into

Say these before the tester finds them. Each is how the product works today, not a fault in the demo.

- **A reload starts a new conversation.** The chat is not saved anywhere. Reloading the page, or leaving it and coming back, gives an empty chat.
- **A conversation searches once, unless you ask it to search again.** The passages found for the first question are the ones every ordinary follow-up is answered from. A follow-up on the same subject works well; a second question about something else is answered from the wrong passages, or not at all. For a new subject, either reload the page or ask with **Manual selection** switched on: a manual-selection question always searches afresh, and the follow-ups after it use what it found.
- **An upload needs its tab.** Ingestion runs for as long as the upload page is open. Closing the tab or navigating away stops it. There is no progress bar: the page says it is working until it is done.
- **Give a new document half a minute.** The search index takes in new passages every 30 seconds, so a question asked sooner than that after the upload page says "Ingestion complete" can find nothing, and the follow-ups in that conversation then find nothing either (see "A conversation searches once"). The upload page's own link to the chat leads straight into this. Step 6's detour through the documents list uses up some of the half minute, not necessarily all of it: count to thirty before step 7. If an answer says it found nothing about a document you just uploaded, wait a moment, then reload the chat and ask again.
- **Scanned PDFs do not work.** A PDF that is pictures of pages has no text to read. It uploads, and it is listed as Completed, but nothing in it can be found. Use a PDF whose text can be selected in a PDF viewer.
- **The upload's figures count sections, not files.** "6 indexed" is six passages of one document.
- **The same file twice is not ingested twice.** Uploading a file that is already in the library reports nothing indexed and nothing failed.
- **Answers are plain text.** A list or a heading in an answer is shown as the model typed it, not formatted.
- **A title can be wrong.** The title is whatever the PDF says its title is, which is sometimes a file name or nothing ("Untitled").
- **Documents belong to everyone.** Every login sees and searches every uploaded document, and nothing can be deleted from the screens.
- **The browser tab has no icon.** Cake does not have one yet.
