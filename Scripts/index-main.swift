import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser.path
let folders = ["\(home)/Documents/Claude/Projects"]

FileHandle.standardError.write("Index-Start \(Date()) — Ordner: \(folders)\n".data(using: .utf8)!)

let emb = OllamaEmbeddingClient(baseURL: "http://127.0.0.1:11434", model: "nomic-embed-text")
let store = KnowledgeStore()
let indexer = KnowledgeIndexer(embedding: emb, store: store)

let sema = DispatchSemaphore(value: 0)
Task {
    let r = await indexer.reindex(folders: folders, history: [])
    // chunkCount erzwingt Flush aller asynchronen Schreibzugriffe (queue.sync-Barriere).
    let total = store.chunkCount
    print("FERTIG  Dateien=\(r.filesIndexed)  neueChunks=\(r.chunks)  übersprungen=\(r.skipped)  Fehler=\(r.errors)  ChunksImStore=\(total)")
    sema.signal()
}
sema.wait()
