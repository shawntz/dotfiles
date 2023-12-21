'use strict';
Object.defineProperty(exports, "__esModule", { value: true });
const commander_1 = require("commander");
const phil_1 = require("@magobaol/phil");
const getAlfredItemFromTextFilter_1 = require("./getAlfredItemFromTextFilter");
const program = new commander_1.Command();
program
    .name('alfred-phil')
    .version('1.0.0')
    .description('Filter text in input')
    .argument('<string>', 'Text to filter')
    .addOption(new commander_1.Option('-cc, --convert-case <string>', 'Convert case').choices([
    'space',
    'upper', 'lower', 'title', 'sentence', 'camel', 'pascal', 'snake', 'spinal'
]));
program.parse();
const options = program.opts();
let textTransformer = new phil_1.TextTransformer(program.args[0]);
let results = {};
if (options.convertCase) {
    let item = '';
    switch (options.convertCase) {
        case 'space':
            item = textTransformer.toSpace().getText();
            break;
        case 'upper':
            item = textTransformer.toUpper().getText();
            break;
        case 'lower':
            item = textTransformer.toLower().getText();
            break;
        case 'title':
            item = textTransformer.toTitle().getText();
            break;
        case 'sentence':
            item = textTransformer.toSentence().getText();
            break;
        case 'camel':
            item = textTransformer.toCamel().getText();
            break;
        case 'pascal':
            item = textTransformer.toPascal().getText();
            break;
        case 'snake':
            item = textTransformer.toSnake().getText();
            break;
        case 'spinal':
            item = textTransformer.toSpinal().getText();
            break;
    }
    process.stdout.write(item);
}
else {
    results = {
        items: [
            (0, getAlfredItemFromTextFilter_1.getAlfredItemFromTextFilter)(textTransformer.toSpace().getLastFilter()),
            (0, getAlfredItemFromTextFilter_1.getAlfredItemFromTextFilter)(textTransformer.toUpper().getLastFilter()),
            (0, getAlfredItemFromTextFilter_1.getAlfredItemFromTextFilter)(textTransformer.toLower().getLastFilter()),
            (0, getAlfredItemFromTextFilter_1.getAlfredItemFromTextFilter)(textTransformer.toTitle().getLastFilter()),
            (0, getAlfredItemFromTextFilter_1.getAlfredItemFromTextFilter)(textTransformer.toSentence().getLastFilter()),
            (0, getAlfredItemFromTextFilter_1.getAlfredItemFromTextFilter)(textTransformer.toCamel().getLastFilter()),
            (0, getAlfredItemFromTextFilter_1.getAlfredItemFromTextFilter)(textTransformer.toPascal().getLastFilter()),
            (0, getAlfredItemFromTextFilter_1.getAlfredItemFromTextFilter)(textTransformer.toSnake().getLastFilter()),
            (0, getAlfredItemFromTextFilter_1.getAlfredItemFromTextFilter)(textTransformer.toSpinal().getLastFilter()),
        ]
    };
    process.stdout.write(JSON.stringify(results));
}
//# sourceMappingURL=phil.js.map