import { mountVault } from './App';
import './App.css';

const root = document.getElementById('root');
if (!root) throw new Error('Swara vault root element was not found.');
mountVault(root);
