const examples = [
  { speech: '«привет <em>запятая</em> мир <em>точка</em>»', text: 'Привет, мир.' },
  { speech: '«первая строка <em>новая строка</em> вторая строка»', text: 'Первая строка\nВторая строка' },
  { speech: '«<em>замени</em> проверка <em>на</em> тест»', text: 'Это проверка. → Это тест.' }
];
for (const button of document.querySelectorAll('[data-example]')) {
  button.addEventListener('click', () => {
    const example = examples[Number(button.dataset.example)];
    document.getElementById('spoken').innerHTML = example.speech;
    document.getElementById('result').textContent = example.text;
    for (const other of document.querySelectorAll('[data-example]')) {
      other.classList.toggle('selected', other === button);
      other.setAttribute('aria-pressed', String(other === button));
    }
  });
}
const downloadButton = document.getElementById('download-app');
const downloadStatus = document.getElementById('download-status');
downloadButton.addEventListener('click', async () => {
  downloadButton.disabled = true;
  try {
    downloadStatus.textContent = 'Подготавливаем архив…';
    const response = await fetch('downloads/release.json');
    if (!response.ok) throw new Error('manifest');
    const release = await response.json();
    const parts = [];
    for (let i = 0; i < release.parts.length; i++) {
      downloadStatus.textContent = `Скачивание: ${Math.round(i / release.parts.length * 100)}%`;
      const part = await fetch(`downloads/${release.parts[i]}`);
      if (!part.ok) throw new Error('download');
      parts.push(await part.arrayBuffer());
    }
    const blob = new Blob(parts, { type: 'application/zip' });
    if (blob.size !== release.bytes) throw new Error('size');
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url; link.download = release.filename;
    document.body.appendChild(link); link.click(); link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 60000);
    downloadStatus.textContent = 'Архив готов. Распакуйте его и запустите VoskWordListener.exe.';
  } catch {
    downloadStatus.textContent = 'Не удалось скачать архив. Проверьте соединение и попробуйте ещё раз.';
  } finally { downloadButton.disabled = false; }
});
