// This "use" statement brings types into scope, like Elixir's "alias"
use pdf_extract::Document;
use rustler::{Binary, NifStruct};

// This derives Rustler's automatic serialization to Elixir terms.
// The "module" attribute tells Rustler what Elixir module to decode into.

#[derive(NifStruct)]
#[module = "Caque.Books.PageContent"]
struct PageContent {
    page_number: u32,
    text: String,
}

#[derive(NifStruct)]
#[module = "Caque.Books.PdfExtraction"]
struct PdfExtraction {
    pages: Vec<PageContent>,
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
    let doc = Document::load_mem(bytes).map_err(|e| format!("PDF load failed: {}", e))?;

    // The ? operator is Rust's early return for errors.
    // If load_mem returns Err, we exit here with that error.
    // If it returns Ok(document), we unwrap and continue.

    // get_pages() returns BTreeMap<u32, ObjectId> where the key
    // is the page number (1-indexed) and value is internal PDF ref.
    // We only care about the keys (page numbers).
    let page_numbers: Vec<u32> = doc.get_pages().keys().cloned().collect();

    // Now we need to extract text from each page.
    // We'll build up a Vec<PageContent> to return.
    let mut pages: Vec<PageContent> = Vec::new();

    // Iterate over each page number
    for page_num in page_numbers {
        // extract_text takes a slice of page numbers.
        // We pass a single-element slice to get one page at a time.
        let text = doc
            .extract_text(&[page_num])
            .map_err(|e| format!("Text extraction failed on page {}: {}", page_num, e))?;

        pages.push(PageContent {
            page_number: page_num,
            text,
        });
    }

    // Return success with our extraction result.
    // Rustler will automatically convert this to an Elixir struct.
    Ok(PdfExtraction { pages })
}

// This macro generates the boilerplate that connects to the BEAM.
// "Elixir.Caque.ParseBooks" becomes the module that loads the NIF.
rustler::init!("Elixir.Caque.ParseBooks");
