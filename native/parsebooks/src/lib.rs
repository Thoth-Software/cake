use pdf_extract::Document;
use rustler::{Binary, NifStruct};

#[derive(NifStruct)]
#[module = "Cake.Books.PageContent"]
struct PageContent {
    page_number: u32,
    text: String,
}

#[derive(NifStruct)]
#[module = "Cake.Books.SkippedPage"]
struct SkippedPage {
    page_number: u32,
    reason: String,
}

#[derive(NifStruct)]
#[module = "Cake.Books.PdfExtraction"]
struct PdfExtraction {
    pages: Vec<PageContent>,
    skipped: Vec<SkippedPage>,
}

// The #[rustler::nif] attribute marks this as callable from Elixir.
// "schedule = DirtyCpu" means: run this on a dirty scheduler because
// it might take a while and we don't want to block the BEAM.
#[rustler::nif(schedule = "DirtyCpu")]
fn extract_pdf(binary: Binary) -> Result<PdfExtraction, String> {
    // Binary is Rustler's type for Elixir binaries. It's a reference
    // to bytes owned by the BEAM, so no copying happens here.

    // as_slice() gives us a &[u8] (a "slice"—a reference to a
    // contiguous sequence of bytes). This is what load_mem expects.
    let bytes: &[u8] = binary.as_slice();

    // Document::load_mem attempts to parse the PDF from memory.
    // It returns Result<Document, Error>. The map_err converts
    // any error into a String (which becomes an Elixir error tuple).
    // If the PDF can't be loaded at all, fail the whole extraction.
    let doc = Document::load_mem(bytes)
        .map_err(|e| format!("PDF load failed: {}", e))?;

    // get_pages() returns BTreeMap<u32, ObjectId> where the key
    // is the page number (1-indexed) and value is internal PDF ref.
    // We only care about the keys (page numbers).
    let page_numbers: Vec<u32> = doc.get_pages().keys().cloned().collect();

    let mut pages: Vec<PageContent> = Vec::new();
    let mut skipped: Vec<SkippedPage> = Vec::new();

    for page_num in page_numbers {
        // extract_text takes a slice of page numbers.
        // We pass a single-element slice to get one page at a time.
        // Failed pages are recorded in skipped rather than aborting the whole extraction.
        match doc.extract_text(&[page_num]) {
            Ok(text) => {
                pages.push(PageContent {
                    page_number: page_num,
                    text,
                });
            }
            Err(e) => {
                skipped.push(SkippedPage {
                    page_number: page_num,
                    reason: format!("{}", e),
                });
            }
        }
    }

    // Return success with our extraction result.
    // Rustler will automatically convert this to an Elixir struct.
    Ok(PdfExtraction { pages, skipped })
}

// This macro generates the boilerplate that connects to the BEAM.
// "Elixir.Cake.ParseBooks" becomes the module that loads the NIF.
rustler::init!("Elixir.Cake.ParseBooks");
