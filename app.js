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
(() => {
  const text = document.getElementById('trial-text');
  const count = document.getElementById('trial-count');
  const status = document.getElementById('trial-status');
  const start = document.getElementById('trial-start');
  const stop = document.getElementById('trial-stop');
  const clear = document.getElementById('trial-clear');
  if (!text) return;
  const wordCount = value => (value.trim().match(/\S+/gu) || []).length;
  const updateCount = () => { count.textContent = `${used} / 100 слов`; };
  let used = 0, finalized = '', model = null, modelLoading = null, recognizer = null;
  let stream = null, audioContext = null, source = null, processor = null, active = false, generation = 0;
  const setActive = value => { active = value; start.disabled = value || used >= 100; stop.disabled = !value; clear.disabled = value; };
  const cleanup = () => {
    if (processor) { processor.onaudioprocess = null; try { processor.disconnect(); } catch {} processor = null; }
    if (source) { try { source.disconnect(); } catch {} source = null; }
    if (stream) { stream.getTracks().forEach(track => track.stop()); stream = null; }
    if (audioContext) { const context = audioContext; audioContext = null; context.close().catch(() => {}); }
    if (recognizer) { try { recognizer.remove(); } catch {} recognizer = null; }
  };
  const stopTrial = message => { generation++; cleanup(); setActive(false); text.value = finalized; status.textContent = message; };
  const loadModel = () => {
    if (model) return Promise.resolve(model);
    if (!window.Vosk) return Promise.reject(new Error('Не удалось загрузить Vosk WebAssembly. Обновите страницу и попробуйте снова.'));
    if (!modelLoading) {
      modelLoading = window.Vosk.createModel('vosk-model-small-ru-0.22.tar.gz');
      modelLoading.then(value => { model = value; }).catch(() => { modelLoading = null; });
    }
    return modelLoading;
  };
  start.addEventListener('click', async () => {
    if (active || used >= 100) return;
    const run = ++generation;
    setActive(true); status.textContent = 'Загружаем Vosk и русскую модель… При первом запуске загрузка модели может занять минуту.';
    try {
      const loaded = await loadModel();
      if (run !== generation) return;
      stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, channelCount: 1 }, video: false });
      if (run !== generation) { stream.getTracks().forEach(track => track.stop()); stream = null; return; }
      audioContext = new AudioContext(); await audioContext.resume();
      recognizer = new loaded.KaldiRecognizer();
      finalized = text.value.trim(); if (finalized) finalized += ' ';
      const render = interim => {
        const words = finalized.trim().split(/\s+/u).filter(Boolean).slice(0, 100);
        const pending = interim.trim().split(/\s+/u).filter(Boolean).slice(0, Math.max(0, 100 - used));
        text.value = [words.join(' '), pending.join(' ')].filter(Boolean).join(' ');
      };
      recognizer.on('result', event => {
        if (run !== generation) return;
        const phrase = event.result?.text?.trim();
        if (!phrase) return;
        const accepted = phrase.split(/\s+/u).slice(0, Math.max(0, 100 - used));
        if (!accepted.length) return;
        used += accepted.length; updateCount();
        finalized += (finalized ? ' ' : '') + accepted.join(' '); render('');
        if (used >= 100) stopTrial('Лимит 100 слов достигнут. Можно скопировать или отредактировать текст.');
      });
      recognizer.on('partialresult', event => { if (run === generation) render(event.result?.partial || ''); });
      source = audioContext.createMediaStreamSource(stream);
      processor = audioContext.createScriptProcessor(4096, 1, 1);
      processor.onaudioprocess = event => { if (run === generation && recognizer) recognizer.acceptWaveform(event.inputBuffer); };
      source.connect(processor); processor.connect(audioContext.destination);
      status.textContent = 'Слушаю… Говорите по-русски. Аудио обрабатывается на этом устройстве.';
    } catch (error) {
      if (run !== generation) return;
      stopTrial(error?.name === 'NotAllowedError' ? 'Нет доступа к микрофону. Разрешите его в настройках браузера.' : (error?.message || 'Не удалось запустить Vosk. Обновите страницу и попробуйте снова.'));
    }
  });
  stop.addEventListener('click', () => stopTrial('Диктовка остановлена.'));
  clear.addEventListener('click', () => { text.value = ''; finalized = ''; used = 0; updateCount(); start.disabled = false; status.textContent = 'Нажмите «Начать диктовку», чтобы попробовать снова.'; });
  text.addEventListener('input', () => {
    if (active) return;
    used = Math.min(100, wordCount(text.value)); finalized = text.value.trim(); updateCount(); start.disabled = used >= 100;
    if (used >= 100) status.textContent = 'Лимит 100 слов достигнут. Очистите текст, чтобы начать заново.';
  });
  updateCount(); setActive(false);
})();
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
