// ════════════════════════════════════════════════════════════════
// ENOSCRIGNO — Tabelle dati geografiche/di riferimento
//
// Puro dato statico (regioni, province, denominazioni, vitigni,
// delegazioni associative) estratto da index.html in un file a parte:
// nessuna di queste costanti viene mai riassegnata, solo lette, quindi
// l'estrazione è un'importazione ESM senza alcun impatto sul
// comportamento — serve solo a tenere il file principale più leggero.
// ════════════════════════════════════════════════════════════════

export const GEO_REGIONS = {
  Italia: ['Piemonte','Valle d\'Aosta','Lombardia','Trentino-Alto Adige','Veneto','Friuli-Venezia Giulia','Liguria','Emilia-Romagna','Toscana','Umbria','Marche','Lazio','Abruzzo','Molise','Campania','Puglia','Basilicata','Calabria','Sicilia','Sardegna'],
  Francia: ['Alsazia','Beaujolais','Bordeaux','Borgogna','Champagne','Corsica','Jura','Languedoc-Roussillon','Valle della Loira','Provenza','Valle del Rodano','Savoia','Sud-Ovest'],
  Germania: ['Ahr','Baden','Franconia','Hessische Bergstraße','Mittelrhein','Mosella','Nahe','Palatinato','Rheingau','Rheinhessen','Saale-Unstrut','Sassonia','Württemberg'],
  Spagna: ['Rioja','Ribera del Duero','Priorat','Penedès','Rías Baixas','Jerez','Navarra','Rueda','Toro','Bierzo','La Mancha','Jumilla','Somontano','Catalogna','Galizia','Andalusia','Castiglia e León','Aragona','Paesi Baschi','Canarie'],
  'Stati Uniti': ['Napa Valley','Sonoma County','Central Coast','Paso Robles','Santa Barbara County','Willamette Valley (Oregon)','Columbia Valley (Washington)','Finger Lakes (New York)'],
  Cile: ['Valle de Elqui','Valle de Limarí','Valle de Aconcagua','Valle de Casablanca','Valle de San Antonio','Valle del Maipo','Valle de Cachapoal','Valle de Colchagua','Valle de Curicó','Valle del Maule','Valle del Itata','Valle del Bío Bío'],
  Argentina: ['Mendoza','Salta','San Juan','La Rioja','Catamarca','Río Negro','Neuquén'],
  'Nuova Zelanda': ['Marlborough','Hawke\'s Bay','Central Otago','Wairarapa (Martinborough)','Nelson','Canterbury (Waipara)','Gisborne','Auckland (Waiheke Island)'],
  'Sud Africa': ['Stellenbosch','Paarl','Franschhoek','Constantia','Swartland','Walker Bay','Robertson','Elgin'],
  Australia: ['Barossa Valley','McLaren Vale','Hunter Valley','Margaret River','Yarra Valley','Coonawarra','Clare Valley','Adelaide Hills','Eden Valley','Mornington Peninsula']
};

export const GEO_PROVINCES_ITALIA = {
  'Piemonte': ['Alessandria','Asti','Biella','Cuneo','Novara','Torino','Verbano-Cusio-Ossola','Vercelli'],
  'Valle d\'Aosta': ['Aosta'],
  'Lombardia': ['Bergamo','Brescia','Como','Cremona','Lecco','Lodi','Mantova','Milano','Monza e Brianza','Pavia','Sondrio','Varese'],
  'Trentino-Alto Adige': ['Trento','Bolzano'],
  'Veneto': ['Belluno','Padova','Rovigo','Treviso','Venezia','Verona','Vicenza'],
  'Friuli-Venezia Giulia': ['Gorizia','Pordenone','Trieste','Udine'],
  'Liguria': ['Genova','Imperia','La Spezia','Savona'],
  'Emilia-Romagna': ['Bologna','Ferrara','Forlì-Cesena','Modena','Parma','Piacenza','Ravenna','Reggio Emilia','Rimini'],
  'Toscana': ['Arezzo','Firenze','Grosseto','Livorno','Lucca','Massa-Carrara','Pisa','Pistoia','Prato','Siena'],
  'Umbria': ['Perugia','Terni'],
  'Marche': ['Ancona','Ascoli Piceno','Fermo','Macerata','Pesaro e Urbino'],
  'Lazio': ['Frosinone','Latina','Rieti','Roma','Viterbo'],
  'Abruzzo': ['Chieti','L\'Aquila','Pescara','Teramo'],
  'Molise': ['Campobasso','Isernia'],
  'Campania': ['Avellino','Benevento','Caserta','Napoli','Salerno'],
  'Puglia': ['Bari','Barletta-Andria-Trani','Brindisi','Foggia','Lecce','Taranto'],
  'Basilicata': ['Matera','Potenza'],
  'Calabria': ['Catanzaro','Cosenza','Crotone','Reggio Calabria','Vibo Valentia'],
  'Sicilia': ['Agrigento','Caltanissetta','Catania','Enna','Messina','Palermo','Ragusa','Siracusa','Trapani'],
  'Sardegna': ['Cagliari','Nuoro','Oristano','Sassari','Sud Sardegna']
};

/* ══ DOC / DOCG / AOC / AVA / GI / WO — suggerimenti per uniformare il campo
   denominazione ══
   Non è un elenco esaustivo (l'Italia da sola ha oltre 400 DOC/DOCG):
   copre le DOCG italiane (elenco chiuso, ~78) organizzate per regione, più
   le denominazioni principali per Francia, Germania, Spagna e per i
   produttori extraeuropei più diffusi in cantina (Stati Uniti, Cile,
   Argentina, Nuova Zelanda, Sud Africa).
   Il campo resta di testo libero — questi sono solo suggerimenti. */
export const ITALY_DOCG = {
  'Piemonte': ['Alta Langa','Asti / Moscato d\'Asti','Barbaresco','Barbera d\'Asti','Barbera del Monferrato Superiore','Barolo','Brachetto d\'Acqui','Canelli / Moscato di Canelli','Gavi (Cortese di Gavi)','Diano d\'Alba (Dolcetto di Diano d\'Alba)','Dogliani (Dolcetto di Dogliani Superiore)','Ovada (Dolcetto di Ovada Superiore)','Erbaluce di Caluso (Caluso)','Gattinara','Ghemme','Nizza','Ruché di Castagnole Monferrato','Roero','Terre Alfieri'],
  'Valle d\'Aosta': [],
  'Lombardia': ['Franciacorta','Moscato di Scanzo','Oltrepò Pavese Metodo Classico','Sforzato di Valtellina','Valtellina Superiore'],
  'Trentino-Alto Adige': [],
  'Veneto': ['Amarone della Valpolicella','Recioto della Valpolicella','Bardolino Superiore','Soave Superiore','Recioto di Soave','Conegliano Valdobbiadene Prosecco Superiore','Colli Asolani Prosecco Superiore (Asolo Prosecco)','Colli di Conegliano','Piave Malanotte (Malanotte del Piave)','Lison','Montello Rosso','Recioto di Gambellara'],
  'Friuli-Venezia Giulia': ['Ramandolo','Colli Orientali del Friuli Picolit','Rosazzo'],
  'Liguria': [],
  'Emilia-Romagna': ['Albana di Romagna','Colli Bolognesi Pignoletto'],
  'Toscana': ['Brunello di Montalcino','Carmignano','Chianti Classico','Chianti','Elba Aleatico Passito','Montecucco Sangiovese','Morellino di Scansano','Suvereto','Val di Cornia Rosso','Vernaccia di San Gimignano','Vino Nobile di Montepulciano'],
  'Umbria': ['Montefalco Sagrantino','Torgiano Rosso Riserva'],
  'Marche': ['Conero (Conero Riserva)','Offida','Verdicchio dei Castelli di Jesi Riserva','Vernaccia di Serrapetrona'],
  'Lazio': ['Cesanese del Piglio (Piglio)','Cannellino di Frascati','Frascati Superiore'],
  'Abruzzo': ['Colline Teramane Montepulciano d\'Abruzzo','Tullum'],
  'Molise': [],
  'Campania': ['Taurasi','Fiano di Avellino','Greco di Tufo'],
  'Puglia': ['Castel del Monte Bombino Nero','Castel del Monte Nero di Troia Riserva','Castel del Monte Rosso Riserva','Primitivo di Manduria Dolce Naturale'],
  'Basilicata': ['Aglianico del Vulture Superiore'],
  'Calabria': [],
  'Sicilia': ['Cerasuolo di Vittoria'],
  'Sardegna': ['Vermentino di Gallura Superiore']
};

export const FRANCE_AOC = {
  'Alsazia': ['Alsace','Alsace Grand Cru','Crémant d\'Alsace'],
  'Beaujolais': ['Beaujolais','Beaujolais-Villages','Morgon','Fleurie','Moulin-à-Vent','Chiroubles','Brouilly','Saint-Amour'],
  'Bordeaux': ['Bordeaux','Bordeaux Supérieur','Médoc','Haut-Médoc','Margaux','Pauillac','Saint-Émilion','Pomerol','Graves','Sauternes','Pessac-Léognan'],
  'Borgogna': ['Bourgogne','Chablis','Gevrey-Chambertin','Vosne-Romanée','Meursault','Puligny-Montrachet','Pommard','Mâcon'],
  'Champagne': ['Champagne'],
  'Corsica': ['Ajaccio','Patrimonio','Vin de Corse'],
  'Jura': ['Côtes du Jura','Château-Chalon','Arbois'],
  'Languedoc-Roussillon': ['Languedoc','Corbières','Minervois','Faugères','Fitou','Collioure'],
  'Valle della Loira': ['Sancerre','Pouilly-Fumé','Vouvray','Chinon','Muscadet','Saumur-Champigny'],
  'Provenza': ['Côtes de Provence','Bandol','Cassis'],
  'Valle del Rodano': ['Côtes du Rhône','Châteauneuf-du-Pape','Hermitage','Côte-Rôtie','Gigondas','Vacqueyras'],
  'Savoia': ['Vin de Savoie','Roussette de Savoie'],
  'Sud-Ovest': ['Cahors','Madiran','Jurançon','Bergerac']
};

export const GERMANY_DESIGNATIONS = ['Qualitätswein','Kabinett','Spätlese','Auslese','Beerenauslese (BA)','Trockenbeerenauslese (TBA)','Eiswein','Prädikatswein','Erste Lage','Grosses Gewächs (GG)','Classic','Selection'];

export const USA_AVA = {
  'Napa Valley': ['Napa Valley AVA','Stags Leap District AVA','Oakville AVA','Rutherford AVA','Howell Mountain AVA'],
  'Sonoma County': ['Sonoma Valley AVA','Russian River Valley AVA','Alexander Valley AVA','Dry Creek Valley AVA'],
  'Central Coast': ['Central Coast AVA','Edna Valley AVA','Santa Maria Valley AVA'],
  'Paso Robles': ['Paso Robles AVA'],
  'Santa Barbara County': ['Santa Ynez Valley AVA','Sta. Rita Hills AVA'],
  'Willamette Valley (Oregon)': ['Willamette Valley AVA','Dundee Hills AVA','Eola-Amity Hills AVA'],
  'Columbia Valley (Washington)': ['Columbia Valley AVA','Walla Walla Valley AVA','Yakima Valley AVA'],
  'Finger Lakes (New York)': ['Finger Lakes AVA','Seneca Lake AVA']
};

export const CHILE_DO = {
  'Valle de Elqui': ['Elqui DO'],
  'Valle de Limarí': ['Limarí DO'],
  'Valle de Aconcagua': ['Aconcagua DO'],
  'Valle de Casablanca': ['Casablanca DO'],
  'Valle de San Antonio': ['San Antonio DO','Leyda DO'],
  'Valle del Maipo': ['Maipo Valley DO'],
  'Valle de Cachapoal': ['Cachapoal Valley DO','Rapel Valley DO'],
  'Valle de Colchagua': ['Colchagua Valley DO','Rapel Valley DO'],
  'Valle de Curicó': ['Curicó Valley DO'],
  'Valle del Maule': ['Maule Valley DO'],
  'Valle del Itata': ['Itata Valley DO'],
  'Valle del Bío Bío': ['Bío Bío Valley DO']
};

export const ARGENTINA_IG = {
  Mendoza: ['Luján de Cuyo IG','Valle de Uco IG','Maipú IG','San Rafael IG','Mendoza IG'],
  Salta: ['Valles Calchaquíes IG','Cafayate IG'],
  'San Juan': ['Pedernal Valley IG','Tulum Valley IG'],
  'La Rioja': ['Famatina Valley IG'],
  Catamarca: ['Fiambalá IG'],
  'Río Negro': ['Río Negro IG'],
  Neuquén: ['Neuquén IG']
};

export const NZ_GI = {
  Marlborough: ['Marlborough GI'],
  'Hawke\'s Bay': ['Hawke\'s Bay GI','Gimblett Gravels GI'],
  'Central Otago': ['Central Otago GI'],
  'Wairarapa (Martinborough)': ['Martinborough GI'],
  Nelson: ['Nelson GI'],
  'Canterbury (Waipara)': ['Waipara Valley GI'],
  Gisborne: ['Gisborne GI'],
  'Auckland (Waiheke Island)': ['Waiheke Island GI']
};

export const SOUTHAFRICA_WO = {
  Stellenbosch: ['Stellenbosch WO'],
  Paarl: ['Paarl WO'],
  Franschhoek: ['Franschhoek Valley WO'],
  Constantia: ['Constantia WO'],
  Swartland: ['Swartland WO'],
  'Walker Bay': ['Walker Bay WO','Hemel-en-Aarde Valley WO'],
  Robertson: ['Robertson WO'],
  Elgin: ['Elgin WO']
};

export const AUSTRALIA_GI = {
  'Barossa Valley': ['Barossa Valley GI'],
  'McLaren Vale': ['McLaren Vale GI'],
  'Hunter Valley': ['Hunter Valley GI'],
  'Margaret River': ['Margaret River GI'],
  'Yarra Valley': ['Yarra Valley GI'],
  Coonawarra: ['Coonawarra GI'],
  'Clare Valley': ['Clare Valley GI'],
  'Adelaide Hills': ['Adelaide Hills GI'],
  'Eden Valley': ['Eden Valley GI'],
  'Mornington Peninsula': ['Mornington Peninsula GI']
};

export const SPAIN_DO = {
  'Rioja': ['Rioja DOCa'],
  'Ribera del Duero': ['Ribera del Duero DO'],
  'Priorat': ['Priorat DOQ'],
  'Penedès': ['Penedès DO'],
  'Rías Baixas': ['Rías Baixas DO'],
  'Jerez': ['Jerez-Xérès-Sherry DO'],
  'Navarra': ['Navarra DO'],
  'Rueda': ['Rueda DO'],
  'Toro': ['Toro DO'],
  'Bierzo': ['Bierzo DO'],
  'La Mancha': ['La Mancha DO'],
  'Jumilla': ['Jumilla DO'],
  'Somontano': ['Somontano DO'],
  'Catalogna': ['DO Catalunya','Montsant DO','Empordà DO'],
  'Galizia': ['Valdeorras DO','Ribeiro DO','Monterrei DO'],
  'Andalusia': ['Montilla-Moriles DO','Málaga DO'],
  'Castiglia e León': ['Cigales DO','Arribes DO'],
  'Aragona': ['Cariñena DO','Campo de Borja DO'],
  'Paesi Baschi': ['Getariako Txakolina DO'],
  'Canarie': ['Ycoden-Daute-Isora DO','Abona DO']
};

/* ══ VITIGNI — elenco curato (non esaustivo) per uniformare il campo ══
   Internazionali + principali autoctoni italiani, francesi, tedeschi,
   spagnoli. Il campo resta comunque libero per varietà non elencate. */
export const GRAPE_VARIETIES = [
  // Internazionali
  'Cabernet Sauvignon','Cabernet Franc','Merlot','Pinot Nero','Pinot Grigio','Pinot Bianco',
  'Syrah','Chardonnay','Sauvignon Blanc','Riesling','Gewürztraminer','Viognier',
  'Grenache (Garnacha)','Tempranillo','Malbec','Petit Verdot','Sémillon','Moscato',
  'Zinfandel (Primitivo)','Gamay','Mourvèdre','Carignan','Cinsault','Chenin Blanc',
  // Autoctoni italiani
  'Sangiovese','Nebbiolo','Barbera','Dolcetto','Corvina','Rondinella','Molinara',
  'Garganega','Trebbiano','Vermentino','Glera','Nero d\'Avola','Nerello Mascalese',
  'Nerello Cappuccio','Aglianico','Fiano','Greco','Falanghina','Verdicchio','Vernaccia',
  'Montepulciano','Lambrusco','Croatina','Freisa','Grignolino','Cortese','Arneis',
  'Ribolla Gialla','Friulano','Pignolo','Schiava','Lagrein','Teroldego','Negroamaro',
  'Bombino Bianco','Bombino Nero','Grillo','Catarratto','Malvasia','Ansonica (Inzolia)',
  'Pecorino','Passerina','Sagrantino','Ciliegiolo','Canaiolo','Colorino','Vespolina',
  'Bonarda','Timorasso','Moscato Giallo','Traminer Aromatico','Kerner','Marzemino',
  // Francia (oltre agli internazionali già elencati)
  'Melon de Bourgogne','Ugni Blanc','Colombard','Roussanne','Marsanne','Petit Manseng',
  // Germania (oltre a Riesling già elencato)
  'Müller-Thurgau','Silvaner','Dornfelder','Portugieser','Scheurebe',
  // Spagna (oltre a Tempranillo/Grenache già elencati)
  'Albariño','Verdejo','Bobal','Godello','Mencía','Palomino','Xarel-lo','Macabeo',
  'Monastrell','Graciano','Cariñena (Mazuelo)'
];

// Suggerimenti per il campo "Delegazione" (autocomplete, non un elenco chiuso —
// vedi attachAutocomplete('p-delegazione', ...) in index.html). Non è l'elenco
// ufficiale completo di ciascuna associazione (FISAR ne ha decine, organizzate
// per provincia): è un punto di partenza, il campo accetta comunque testo libero.
export const DELEGAZIONI = {
  AIS: ['Abruzzo','Basilicata','Calabria','Campania','Emilia Romagna','Friuli Venezia Giulia','Lazio','Liguria','Lombardia','Marche','Molise','Piemonte','Puglia','Sardegna','Sicilia','Toscana','Trentino Alto Adige','Umbria','Valle d\'Aosta','Veneto'],
  FISAR: ['Delegazione di Alessandria','Delegazione di Bari','Delegazione di Bologna','Delegazione di Caserta','Delegazione di Civitavecchia e Costa Etrusco-Romana','Delegazione di Empoli','Delegazione di Firenze','Delegazione di Genova','Delegazione di Livorno','Delegazione di Lucca','Delegazione di Milano','Delegazione di Napoli','Delegazione di Palermo','Delegazione di Pavia','Delegazione di Pesaro-Urbino-Fano','Delegazione di Pisa','Delegazione di Portogruaro','Delegazione di Prato','Delegazione di Roma','Delegazione di Torino','Delegazione di Venezia','Delegazione di Verona'],
  ONAV: ['Sezione di Bologna','Sezione di Firenze','Sezione di Milano','Sezione di Napoli','Sezione di Padova','Sezione di Roma','Sezione di Torino','Sezione di Venezia'],
  FIS: ['Fondazione Ancona','Fondazione Andria','Fondazione Bergamo','Fondazione Bologna','Fondazione Cagliari','Fondazione Catania','Fondazione Fondi','Fondazione Franciacorta','Fondazione Frosinone','Fondazione Genova','Fondazione Grosseto','Fondazione Grottaferrata','Fondazione Lecce','Fondazione Mantova','Fondazione Milano','Fondazione Napoli','Fondazione Padova','Fondazione Pescara','Fondazione Pisa','Fondazione Roma','Fondazione Siena','Fondazione Torino','Fondazione Treviso','Fondazione Val d\'Orcia','Fondazione Verona','Fondazione Vicenza']
};
