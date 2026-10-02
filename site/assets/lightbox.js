// Click a zoomable figure to open it full size over the page; click away, or press Escape, to
// close. Hand-written and dependency-free to match the rest of this directory, and progressive:
// the trigger is a plain link to the image, so with scripting off a click just opens the file.
(function () {
  var dialog = document.getElementById('lightbox');
  if (!dialog) return;

  var view = dialog.querySelector('img');
  var close = dialog.querySelector('.lightbox-close');

  document.addEventListener('click', function (event) {
    var trigger = event.target.closest ? event.target.closest('a.zoom') : null;
    if (!trigger) return;

    // preventDefault, not a no-op: without scripting the click has to reach the image itself.
    event.preventDefault();

    var thumb = trigger.querySelector('img');
    view.src = trigger.href;
    view.alt = thumb ? thumb.alt : '';

    if (!dialog.open) dialog.showModal();
  });

  // A backdrop click, or a click on the padding around the image, reports the dialog as its
  // target. The image and the close button report themselves, so this fires on "click away" and
  // on nothing else.
  dialog.addEventListener('click', function (event) {
    if (event.target === dialog) dialog.close();
  });

  close.addEventListener('click', function () {
    dialog.close();
  });
})();