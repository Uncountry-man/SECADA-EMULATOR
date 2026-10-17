import { pageHead } from './common.mjs';

export function privacidade() {
  return `
${pageHead('Privacidade', 'O que este site e o programa fazem com a sua rede e os seus dados, hoje. Não é um documento jurídico.')}

<section class="section tight" aria-labelledby="h-site">
  <div class="wrap two">
    <div><h2 id="h-site">Este site</h2></div>
    <ul class="plain-list">
      <li>Não usa cookies, análise de acesso, publicidade nem rastreadores.</li>
      <li>Não faz chamadas a serviços de terceiros: as fontes, as imagens e os scripts são servidos pelo próprio site.</li>
      <li>Baixar o SECADA não exige cadastro, e-mail nem login.</li>
      <li>O único script do navegador copia textos para a área de transferência, abre o menu e avisa se o seu sistema não é Linux x86-64. Nada disso sai do seu navegador.</li>
    </ul>
  </div>
</section>

<section class="section tight" aria-labelledby="h-app">
  <div class="wrap two">
    <div><h2 id="h-app">O programa</h2><p class="aside">O que o SECADA acessa na rede, segundo o próprio código.</p></div>
    <ul class="plain-list">
      <li><strong>Imagem do Android.</strong> O script <code>fetch-android-image.sh</code> baixa a ISO do Android-x86 do SourceForge ou do archive.org e confere o MD5.</li>
      <li><strong>Tradução ARM.</strong> Se a opção estiver ligada, o SECADA baixa o libhoudini de <code>dl.android-x86.org</code> uma vez. A conexão é HTTP, então a integridade vem da conferência do SHA-256, que o SECADA faz antes de usar o arquivo.</li>
      <li><strong>Portas e sockets.</strong> O ADB escuta só em <code>127.0.0.1</code>; o vídeo e o controle usam sockets UNIX privados. O SECADA não abre portas de rede para fora do seu computador.</li>
      <li><strong>Conta.</strong> O SECADA não cria conta nem envia dados de uso para o projeto.</li>
      <li><strong>Android dentro da janela.</strong> O Android tem acesso à internet (NAT do QEMU) e os apps que você instala se comportam como em qualquer Android. A imagem Android-x86 inclui componentes de análise (<code>org.android_x86.analytics</code>) e apps do Google; o modo “Android enxuto”, que é opcional e vem desligado, remove esses pacotes.</li>
    </ul>
  </div>
</section>

<section class="section tight" aria-labelledby="h-data">
  <div class="wrap two">
    <div><h2 id="h-data">Onde ficam os seus dados</h2></div>
    <ul class="plain-list">
      <li>Configurações: <code>~/.config/secada/</code></li>
      <li>Apps e dados do Android: <code>~/.local/share/secada/vms/default/data.qcow2</code></li>
      <li>Registros: <code>~/.local/share/secada/logs/</code></li>
      <li>Tudo isso fica no seu computador. Para apagar, desinstale o SECADA e remova essas pastas.</li>
    </ul>
  </div>
</section>
`;
}
