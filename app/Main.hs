import Editor.GraphEditor

main :: IO ()
main = startGUI

{-
Tarefas ---------------------------------------------------------------------
*Modificar interface para que o painel do inspector não seja mostrado a toda hora.
  *Mostra-lo ao dar 2 cliques em um elemento.
*Criar uma espécie de inferência de tipos de arestas quando criá-las
*Quando editar o nome de uma aresta ou nodo no grafo de tipos, fazer update em todos os grafos que usam o objeto
*permitir que o usuário escolha como será vista a regra (formato L->R, ou L<-K->R)
*permitir a reordenação das regras por drag n' drop
*criação e associação de NACs.
  - modificar informações visuais quando fizer merging dos elementos do lhs
    - arestas retas devem ter posição modificada para não ficarem atrás dos nodos
    - nodos devem ter tamanho modificado para englobar texto
    - modificações de posiciconamento devem ser preservadas



Ideias -------------------------------------------------------------------------
*criação de nodos através de clique duplo em um espaço em branco
*criação de arestas dando clique duplo em um nodo e arrastando mouse para outro nodo
*mostrar um campo de digitação em cima do elemento quando o usuario apertar F2 para renomeá-lo
*mostrar menu de contexto ao clicar em um elemento com o botão direito

Progresso -------------------------------------------------------------------
*Mostrar regras em formato R -> L
*criação e associação de NACs.
  - indicar quais são os elementos da nac que são do lhs e não permitir a deleção/renomeação de elementos do lhs
    - [X] deleção
    - [ ] renomeação
  - concatenação de elementos do lhs na nac.
    - checar se as arestas a serem concatenadas têm as mesmas origens e destinos.
    - verificar os tipos dos elementos a serem concatenados.
  - separação de elementos concatenados
    - recuperar nome correto do elemento



Feito -----------------------------------------------------------------------
*Melhorar menu de Propriedades
 *3 aparencias diferentes para nodos, edges e nodos+edges
*Corrigir Zoom para ajustar o Pan quando ele for modificado
*Copy/Paste/Cut
*Corrigir arestas não sendo coladas com Cut/Paste
*Corrigir movimento das arestas quando mover um nodo
*corrigir bug no copiar/colar que ocorre quando a seleção é movida antes de copiar
*Novo Arquivo
*Separar a estrutura do grafo das estruturas gráficas
*Estilos diferentes para as arestas
*Criar uma janela de mensagens de erros para substituir prints
*Mudar para que quando o usuario clique em um nodo, ele não invalide toda a seleção se o nodo for parte da seleção
*Fazer com que duplo-clique em um nodo ou aresta ou pressionando F2 com nodos/arestas selecionados, o dialogo nome seja focado
*Mudar estrutura do grafo para estrutura usada no verigraph
*Editar multiplos grafos no mesmo projeto
  *Criar uma arvore de grafos
  *Consertar Undo/Redo
*Espaçar edges quando houver mais de uma aresta entre dois nodos e ela estiver centralizada
*Removida a opção "Insert Emoji" do menu da treeView, porque a ativação estava fazendo o programa encerrar.
*Arrumado bug que fazia o programa encerrar ao salvar com algum grafo que não o primeiro selecionado.
*Indicar em qual grafo está a mudança do projeto
*Mudar a linguagem dos comentários para inglês
*Perguntar se o usuario quer salvar o grafo no caso de ativar a ação 'new'
*Mudar a linguagem da interface toda para inglês
*Mudar o modelo da treeview para uma treeStore
*Modificar a aplicação para aceitar ramificações da treestore
  *Durante a edição
  *Salvar/Carregar
*Adicionar diferentes tipos de grafos, mudando o inspector (painel a direita) quando o usuario clicar nele
  *Typed - grafo com mais liberdade de opções, define os tipos dos elementos
  *Host - grafos em que elementos são associados a um tipo e herdam a informação visual desses elementos
  *Rule  - grafo em que elementos indicam transformações sobre grafos Host
*Verificar se um elemento do hostGraph foi mapeado corretamente para TypedGraph
*Adicionar coluna na treeView para indicar mudança
*Atualizar informações do typegraph ativado automaticamente durante a edição
*Arrumar função para indicar mudanças - ela está indicando mudanças em nodos do tipo Topic
*Indicar conflitos no typeGraph
*Informar erros nos hostGraphs e rulesGraphs assim que o typeGraph for modificado
*Adicionar coluna na treeview para atributo de ativação de ruleGraphs
*Associar informação de operação para ruleGraphs
*Validar operações em ruleGraphs
 - arestas não podem conectar um objeto que sera deletado
 - endoarestas não podem ser deletadas de um objeto que será criado
*Mostrar informação de operação para elementos de ruleGraphs
*Transformar um ruleGraph em 3 grafos diferentes: LHS, K e RHS
*Gerar uma especificação de gramática compativel com o Verigraph
*Adicionar menuEntry para exportar gramática para .ggx
*Arrumar bug - objetos tendo a aparencia modificada apenas ao mover se configurar o tipo através da entry
*Arrumar bug - não há informação de erros quando há nodos com mesmo nome no typeGraph
*Arrumar bug - arestas recém criadas em hostGraphs e ruleGraphs não recebem uma label automática.
*Permitir que o usuário controle se os elementos irão receber nomes automáticos ou não
*Exportar nomes dos tipos de nodos e arestas no arquivo ggx
*arrumar bug: renomear elemento em RuleGraph faz com que a informação de operação seja perdida
*criação e associação de NACs.
  - criar grafo que inicia com o lado esquerdo da regra.
  - as mudanças de uma regra devem propagar para as nacs.
    - dividir nac de forma a pegar apenas a forma da nac e juntar com o lhs quando for edita-la novamente
-}
