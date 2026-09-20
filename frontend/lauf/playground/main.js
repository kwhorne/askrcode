// Lekegrinda. Ikke en del av pakka — den er her for å se komponentene i en
// ekte nettleser, og for at CDP-skriptet i tests/browser/ skal ha noe å
// kjøre mot. jsdom kan ikke bevise fokusfelle, flytende plassering,
// rullelås eller at en kalender lar seg styre med piltaster.
import { mount } from 'svelte'
import App from './App.svelte'
import './app.css'

mount(App, { target: document.querySelector('#app') })
