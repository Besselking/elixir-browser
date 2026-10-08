# Tasks

## Acid3 (http://acid3.acidtests.org/)

- [x] The test runs to completion and shows a score (40/100 with `mix browser.screenshot --js`)
- [x] A failed `appendChild` of an ancestor (live range present) no longer detaches the node first
- [ ] `document.implementation.createDocument` / `createDocumentType` (tests 1-3, 6, 8, 9, 11-13, 26, 33-47)
- [ ] `document.createNodeIterator` and `createTreeWalker` (tests 4, 5)
- [ ] DOM exceptions: `name`, `code` and the `*_ERR` constants (tests 19, 25)
- [ ] `document.firstChild` is the doctype (test 18)
- [ ] `createElement` name validation, tagName case for prefixed names (tests 20-23)
- [ ] Table API: `createCaption`, `rows`, `tBodies[].insertRow` (tests 29, 49, 50)
- [ ] `event.initUIEvent` (test 30)
- [ ] `getComputedStyle(...).whiteSpace` (test 0)

## Canvas (QR code generator page)

- [x] `getContext("2d")` with `fillRect`, `strokeRect`, `clearRect` and `toDataURL` (PNG) in `Browser.Canvas`; the QR code on mb.bes.is/qrcodeGenerator is drawn as an image, not a stretched table
- [x] `load` / `error` events for images given a `data:` URL
- [ ] Show a `<canvas>` on the page (it is `display: none` now; pages that show the canvas itself stay blank)
- [ ] Paths, text, `drawImage`, `getImageData` and `fillStyle` gradients
- [ ] `load` / `error` events for images with an http(s) URL made by script
